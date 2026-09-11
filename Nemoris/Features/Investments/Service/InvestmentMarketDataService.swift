import Foundation

struct InvestmentMarketDataFetchResult {
    let identifier: String
    let source: String
    let points: [InvestmentPricePoint]
    /// Every candidate symbol tried during resolution (so the sync trace can
    /// show the full path: "EUEA.AS, EUEA, IE...").
    let attemptedSymbols: [String]
}

struct InvestmentInstrumentMetadata {
    let isin: String
    let name: String
    let symbol: String
    let quoteType: String?
    let currency: String?
    let exchange: String?
}

enum InvestmentMarketDataError: LocalizedError {
    case invalidIdentifier
    /// No source returned any points. Carries the list of symbols tried, so a
    /// verbose diagnostic can be shown in the sync trace ("Symbols tried:
    /// EUEA.AS, EUEA, IE0008471009 — none found").
    case noData(attemptedSymbols: [String])
    /// 0 points AND at least one provider answered 429 during resolution —
    /// distinct from noData (the asset may well exist, it's only temporarily
    /// blocked). `retryAfter` = seconds before a retry is possible.
    case rateLimited(provider: MarketDataProvider, retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "Identifiant invalide (ticker/ISIN manquant)."
        case .noData(let symbols):
            if symbols.isEmpty {
                return "Aucune donnée marché trouvée."
            }
            return "Aucune donnée marché trouvée. Symboles essayés : \(symbols.joined(separator: ", "))."
        case .rateLimited(let provider, let retryAfter):
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "Limite de requêtes atteinte (\(provider.displayName)). Réessaie dans \(minutes) min."
        }
    }
}

struct InvestmentMarketDataService {
    private let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func fetchHistory(identifier: String) async throws -> InvestmentMarketDataFetchResult {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestmentMarketDataError.invalidIdentifier }

        // Candidates come from 2 sources combined:
        //
        //   1. OpenFIGI: ISIN → ticker + exchange mapping, from which the Yahoo
        //      symbol is derived via buildSymbolCandidates (e.g. NA → .AS).
        //   2. Yahoo search: the ISIN is searched directly on the search API, which
        //      returns raw Yahoo symbols (suffix already included).
        //
        // With OpenFIGI alone, an unexpected exchCode (not in the switch below)
        // yields "EUEA" without a suffix → Yahoo 404 → raw ISIN fallback → Yahoo 404
        // as well → "noData". Stacking "EUEA.AS" (seen by Yahoo search) fixes that.
        var candidates: [String] = []
        if isISIN(clean) {
            // Source 1 : OpenFIGI
            if let metadata = await resolveFromOpenFIGI(clean) {
                candidates.append(contentsOf: buildSymbolCandidates(from: metadata))
            }
            // Source 2: Yahoo search — take the first 3 symbols returned (the right
            // one is typically in the top 3)
            let yahooSymbols = await searchYahooSymbols(query: clean, isin: clean)
            candidates.append(contentsOf: yahooSymbols)
            // Fallback: the raw ISIN (in case Yahoo accepts it)
            candidates.append(clean)
        } else {
            // Not an ISIN: try the raw ticker + Yahoo search on it
            candidates.append(clean)
            let yahooSymbols = await searchYahooSymbols(query: clean, isin: nil)
            candidates.append(contentsOf: yahooSymbols)
        }

        // Deduplicate while preserving order (the first candidates take priority)
        var seen = Set<String>()
        let unique = candidates.filter { sym in
            let key = sym.uppercased()
            return seen.insert(key).inserted
        }

        // Try Yahoo then Stooq, in sequence, for each candidate. Every symbol tried
        // is recorded for the diagnostic trace.
        //
        // No `try?` swallowing everything — each error is kept. A rate-limited
        // provider (breaker open) isn't retried for the following candidates (but
        // the other source carries on).
        var yahooBlocked = false
        var stooqBlocked = false
        var lastRateLimited: (provider: MarketDataProvider, retryAfter: TimeInterval)?
        var lastError: Error?

        for symbol in unique {
            // Both sources rate-limited → no point going through the remaining candidates.
            if yahooBlocked && stooqBlocked { break }

            if !yahooBlocked {
                do {
                    let points = try await fetchFromYahoo(symbol: symbol)
                    if !points.isEmpty {
                        return InvestmentMarketDataFetchResult(
                            identifier: symbol, source: "yahoo", points: points,
                            attemptedSymbols: unique
                        )
                    }
                } catch MarketDataFetchError.rateLimited(let provider, let retryAfter) {
                    yahooBlocked = true
                    lastRateLimited = (provider, retryAfter)
                } catch {
                    lastError = error
                }
            }
            if !stooqBlocked {
                do {
                    let points = try await fetchFromStooq(symbol: symbol)
                    if !points.isEmpty {
                        return InvestmentMarketDataFetchResult(
                            identifier: symbol, source: "stooq", points: points,
                            attemptedSymbols: unique
                        )
                    }
                } catch MarketDataFetchError.rateLimited(let provider, let retryAfter) {
                    stooqBlocked = true
                    lastRateLimited = (provider, retryAfter)
                } catch {
                    lastError = error
                }
            }
        }

        // 0 points + at least one 429 → the failure is temporary, not "no data".
        if let lastRateLimited {
            throw InvestmentMarketDataError.rateLimited(
                provider: lastRateLimited.provider,
                retryAfter: lastRateLimited.retryAfter
            )
        }
        if let lastError {
            print("[InvestmentMarketDataService] fetchHistory sans résultat pour \(clean) — dernière erreur : \(lastError)")
        }
        throw InvestmentMarketDataError.noData(attemptedSymbols: unique)
    }

    /// Searches one or more tradable Yahoo symbols matching a query (ISIN,
    /// ticker, asset name). Returns the first 3 results to allow fallbacks (e.g.
    /// the same ETF listed on 2 exchanges).
    private func searchYahooSymbols(query: String, isin: String?) async -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=10") else {
            return []
        }
        do {
            // Best-effort: the search only generates candidates — on failure (including
            // a 429 with the breaker open), carry on without it.
            let data = try await ResilientHTTP.get(url, provider: .yahoo)
            let decoded = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
            // With an ISIN, prefer the quotes that match the ISIN exactly (Yahoo returns
            // it when known)
            var ordered = decoded.quotes
            if let isin {
                let matching = ordered.filter { $0.isin?.uppercased() == isin.uppercased() }
                let others = ordered.filter { $0.isin?.uppercased() != isin.uppercased() }
                ordered = matching + others
            }
            // Take the first 3 non-empty symbols, deduplicated
            var seen = Set<String>()
            var out: [String] = []
            for q in ordered.prefix(10) {
                let upper = q.symbol.uppercased()
                guard !upper.isEmpty, seen.insert(upper).inserted else { continue }
                out.append(upper)
                if out.count >= 3 { break }
            }
            return out
        } catch {
            return []
        }
    }

    func resolveInstrumentFromISIN(_ isin: String) async -> InvestmentInstrumentMetadata? {
        let clean = isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty else {
            return nil
        }

        if let mapped = await resolveFromOpenFIGI(clean) {
            return mapped
        }

        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)") else {
            return nil
        }
        do {
            let data = try await ResilientHTTP.get(url, provider: .yahoo)
            let decoded = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
            guard let best = decoded.quotes.first(where: { quote in
                quote.isin?.uppercased() == clean
            }) ?? decoded.quotes.first else {
                return nil
            }
            let name = best.longname ?? best.shortname ?? best.symbol
            return InvestmentInstrumentMetadata(
                isin: clean,
                name: name,
                symbol: best.symbol,
                quoteType: best.quoteType,
                currency: best.currency,
                exchange: best.exchange
            )
        } catch {
            return nil
        }
    }

    private func resolveFromOpenFIGI(_ isin: String) async -> InvestmentInstrumentMetadata? {
        guard let url = URL(string: "https://api.openfigi.com/v3/mapping") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "[{\"idType\":\"ID_ISIN\",\"idValue\":\"\(isin)\"}]".data(using: .utf8)

        do {
            // Best-effort (nil on failure) but via ResilientHTTP, to benefit from the
            // 2.5 s pacing (25 req/min without a key) and the 429 breaker.
            let data = try await ResilientHTTP.send(request, provider: .openFIGI)
            let decoded = try JSONDecoder().decode([OpenFIGIResult].self, from: data)
            guard let first = decoded.first?.data?.first else { return nil }
            let name = first.name ?? first.ticker ?? isin
            let symbol = first.ticker ?? isin
            return InvestmentInstrumentMetadata(
                isin: isin,
                name: name,
                symbol: symbol,
                quoteType: first.securityType2 ?? first.securityType,
                currency: nil,
                exchange: first.exchCode
            )
        } catch {
            return nil
        }
    }

    func preferredTradableSymbol(from metadata: InvestmentInstrumentMetadata) -> String {
        buildSymbolCandidates(from: metadata).first ?? metadata.symbol
    }

    private func buildSymbolCandidates(from metadata: InvestmentInstrumentMetadata) -> [String] {
        let base = metadata.symbol.uppercased()
        let exchange = (metadata.exchange ?? "").uppercased()
        var candidates: [String] = []

        // OpenFIGI/Bloomberg exchCode → Yahoo Finance suffix mappings.
        // Exhaustive table of European markets + crypto + major US markets where
        // Yahoo needs a suffix.
        let suffix: String?
        switch exchange {
        // Euronext
        case "FP", "PA":                        suffix = ".PA"  // Paris
        case "NA", "AS":                        suffix = ".AS"  // Amsterdam
        case "BB", "BR":                        suffix = ".BR"  // Brussels
        case "ID", "IR":                        suffix = ".IR"  // Dublin
        case "LS":                              suffix = ".LS"  // Lisbon
        case "MI":                              suffix = ".MI"  // Milan
        case "OL", "OS":                        suffix = ".OL"  // Oslo
        // UK
        case "LN", "L", "LON":                  suffix = ".L"   // London
        // Allemagne
        case "GR", "DE", "GY", "XETRA", "ETR":  suffix = ".DE"  // Xetra / Frankfurt
        case "F", "FR":                         suffix = ".F"   // Frankfurt direct
        // Suisse
        case "SW", "SX", "VX":                  suffix = ".SW"  // SIX Swiss
        // Espagne
        case "SM", "MC":                        suffix = ".MC"  // Madrid
        // Sweden / Nordics
        case "SS", "ST":                        suffix = ".ST"  // Stockholm
        case "DC":                              suffix = ".CO"  // Copenhagen
        case "FH":                              suffix = ".HE"  // Helsinki
        // Asie
        case "JP", "JT", "TYO":                 suffix = ".T"   // Tokyo
        case "HK":                              suffix = ".HK"  // Hong Kong
        // Pas de suffixe : exchanges US (NYSE, NASDAQ, etc.), crypto
        default:                                suffix = nil
        }
        if let suffix {
            candidates.append(base + suffix)
            // If the base already contains the suffix (e.g. "EUEA.AS"), Yahoo copes —
            // adding it too is harmless.
        }
        candidates.append(base)
        candidates.append(metadata.isin)
        return candidates
    }

    private func isISIN(_ value: String) -> Bool {
        let pattern = "^[A-Z]{2}[A-Z0-9]{9}[0-9]$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func fetchFromYahoo(symbol: String) async throws -> [InvestmentPricePoint] {
        // range=10y: covers the full history of a typical PEA (opened 5-10 years ago
        //   on average). Gives ~2520 daily points — large compared with 1y, but the
        //   per-date upsert of PriceHistoryCache guarantees zero duplicates.
        // interval=1d: daily precision, required for short ranges (1D, 1W, 1M),
        //   which would otherwise show a nearly empty line.
        //
        // Storage cost: ~2520 points × 50 positions ≈ 126k points = a few MB in the
        // JSON disk cache. Comfortably acceptable.
        //
        // A position older than 10 years gets its "Max" chart truncated to 10 years.
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=10y&interval=1d") else {
            return []
        }
        // ResilientHTTP: pacing + breaker + retry. A 404 (unknown symbol) throws
        // .badStatus → the candidate loop moves to the next one; a 429 throws
        // .rateLimited → Yahoo is blocked for the rest of the resolution.
        let data = try await ResilientHTTP.get(url, provider: .yahoo)
        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first,
              let timestamps = result.timestamp,
              let quotes = result.indicators.quote.first?.close,
              !timestamps.isEmpty else { return [] }

        let opens = result.indicators.quote.first?.open
        var points: [InvestmentPricePoint] = []
        for (idx, ts) in timestamps.enumerated() {
            guard idx < quotes.count, let close = quotes[idx], close > 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            points.append(InvestmentPricePoint(
                id: "\(symbol)-\(Int(ts))",
                identifier: symbol,
                date: date,
                close: close,
                open: openValue(opens, at: idx)
            ))
        }
        return points.sorted { $0.date < $1.date }
    }

    /// Open of candle `idx`, or nil if the source didn't supply it (missing
    /// array, shorter than the timestamps, or a null/negative value).
    private func openValue(_ opens: [Double?]?, at idx: Int) -> Double? {
        guard let opens, idx < opens.count, let value = opens[idx], value > 0 else { return nil }
        return value
    }

    /// INTRADAY prices, ~30 min over the last 48 h (Yahoo `range=2d&interval=30m`).
    /// Takes an ALREADY RESOLVED Yahoo symbol — the one carried by the synced
    /// daily points (`point.identifier`) — to avoid paying for the
    /// OpenFIGI/search resolution again on every tap of the 1D range. Stooq has
    /// no intraday: no fallback, a failure = no 1D view for this security
    /// (clean degradation).
    func fetchIntradayHistory(symbol: String) async throws -> [InvestmentPricePoint] {
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=2d&interval=30m") else {
            return []
        }
        let data = try await ResilientHTTP.get(url, provider: .yahoo)
        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first,
              let timestamps = result.timestamp,
              let quotes = result.indicators.quote.first?.close,
              !timestamps.isEmpty else { return [] }

        let opens = result.indicators.quote.first?.open
        var points: [InvestmentPricePoint] = []
        for (idx, ts) in timestamps.enumerated() {
            guard idx < quotes.count, let close = quotes[idx], close > 0 else { continue }
            points.append(InvestmentPricePoint(
                id: "\(symbol)-i30-\(Int(ts))",
                identifier: symbol,
                date: Date(timeIntervalSince1970: TimeInterval(ts)),
                close: close,
                open: openValue(opens, at: idx)
            ))
        }
        return points.sorted { $0.date < $1.date }
    }

    private func fetchFromStooq(symbol: String) async throws -> [InvestmentPricePoint] {
        let sym = symbol.lowercased()
        guard let url = URL(string: "https://stooq.com/q/d/l/?s=\(sym)&i=d") else { return [] }
        let data = try await ResilientHTTP.get(url, provider: .stooq)
        guard let csv = String(data: data, encoding: .utf8) else { return [] }

        let lines = csv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var points: [InvestmentPricePoint] = []
        for line in lines {
            let cols = line.components(separatedBy: ",")
            // Colonnes Stooq : Date,Open,High,Low,Close,Volume
            guard cols.count >= 5,
                  let date = isoDateFormatter.date(from: cols[0]),
                  let close = Double(cols[4]), close > 0 else { continue }
            let open = Double(cols[1]).flatMap { $0 > 0 ? $0 : nil }
            points.append(InvestmentPricePoint(
                id: "\(symbol)-\(cols[0])",
                identifier: symbol,
                date: date,
                close: close,
                open: open
            ))
        }
        return points.sorted { $0.date < $1.date }
    }
}

private struct YahooChartResponse: Decodable {
    let chart: YahooChartContainer
}

private struct YahooChartContainer: Decodable {
    let result: [YahooChartResult]?
}

private struct YahooChartResult: Decodable {
    let timestamp: [Int]?
    let indicators: YahooIndicators
}

private struct YahooIndicators: Decodable {
    let quote: [YahooQuote]
}

private struct YahooQuote: Decodable {
    let close: [Double?]
    /// Yahoo always returns the full OHLC; only the open is kept (the time step's
    /// "entry price", shown while scrubbing the chart). Optional out of caution:
    /// some exotic instruments only have `close`.
    let open: [Double?]?
}

private struct YahooSearchResponse: Decodable {
    let quotes: [YahooSearchQuote]
}

private struct YahooSearchQuote: Decodable {
    let symbol: String
    let shortname: String?
    let longname: String?
    let quoteType: String?
    let currency: String?
    let exchange: String?
    let isin: String?
}

private struct OpenFIGIResult: Decodable {
    let data: [OpenFIGIInstrument]?
}

private struct OpenFIGIInstrument: Decodable {
    let ticker: String?
    let name: String?
    let exchCode: String?
    let securityType: String?
    let securityType2: String?
}
