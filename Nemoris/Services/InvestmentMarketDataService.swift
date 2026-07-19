import Foundation

struct InvestmentMarketDataFetchResult {
    let identifier: String
    let source: String
    let points: [InvestmentPricePoint]
    /// Tous les symboles candidats essayés pendant la résolution (utile pour
    /// que la trace de sync montre le chemin complet : "EUEA.AS, EUEA, IE...").
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
    /// Aucune source n'a retourné de points. On embarque la liste des symboles
    /// essayés pour pouvoir afficher un diagnostic verbeux dans la trace de
    /// sync ("Symboles essayés : EUEA.AS, EUEA, IE0008471009 — aucun trouvé").
    case noData(attemptedSymbols: [String])

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "Identifiant invalide (ticker/ISIN manquant)."
        case .noData(let symbols):
            if symbols.isEmpty {
                return "Aucune donnée marché trouvée."
            }
            return "Aucune donnée marché trouvée. Symboles essayés : \(symbols.joined(separator: ", "))."
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

        // On combine MAINTENANT 2 sources pour générer les candidats au lieu
        // d'une seule (OpenFIGI) :
        //
        //   1. OpenFIGI : mapping ISIN → ticker + exchange, on en déduit le
        //      symbole Yahoo via buildSymbolCandidates (ex: NA → .AS).
        //   2. Yahoo search : on cherche directement l'ISIN sur l'API search
        //      et on récupère les symboles Yahoo bruts (déjà avec suffixe).
        //
        // Avant : si OpenFIGI rendait un mauvais exchCode (ex: pas dans
        // notre switch), on tombait sur "EUEA" sans suffixe → Yahoo 404 →
        // fallback raw ISIN → Yahoo 404 aussi → "noData". Maintenant on
        // empile "EUEA.AS" (vu par Yahoo search) en plus → ça marche.
        var candidates: [String] = []
        if isISIN(clean) {
            // Source 1 : OpenFIGI
            if let metadata = await resolveFromOpenFIGI(clean) {
                candidates.append(contentsOf: buildSymbolCandidates(from: metadata))
            }
            // Source 2 : Yahoo search — on prend les 3 premiers symboles
            // retournés (typiquement le bon est dans le top 3)
            let yahooSymbols = await searchYahooSymbols(query: clean, isin: clean)
            candidates.append(contentsOf: yahooSymbols)
            // Fallback : l'ISIN brut (au cas où Yahoo accepte l'ISIN)
            candidates.append(clean)
        } else {
            // Non-ISIN : on essaie le ticker brut + Yahoo search dessus
            candidates.append(clean)
            let yahooSymbols = await searchYahooSymbols(query: clean, isin: nil)
            candidates.append(contentsOf: yahooSymbols)
        }

        // Dédupe en préservant l'ordre (priorité aux 1ers candidats)
        var seen = Set<String>()
        let unique = candidates.filter { sym in
            let key = sym.uppercased()
            return seen.insert(key).inserted
        }

        // Essai séquentiel Yahoo puis Stooq pour chaque candidat. On garde
        // trace de tous les symboles tentés pour la trace de diagnostic.
        for symbol in unique {
            if let points = try? await fetchFromYahoo(symbol: symbol), !points.isEmpty {
                return InvestmentMarketDataFetchResult(
                    identifier: symbol, source: "yahoo", points: points,
                    attemptedSymbols: unique
                )
            }
            if let points = try? await fetchFromStooq(symbol: symbol), !points.isEmpty {
                return InvestmentMarketDataFetchResult(
                    identifier: symbol, source: "stooq", points: points,
                    attemptedSymbols: unique
                )
            }
        }

        throw InvestmentMarketDataError.noData(attemptedSymbols: unique)
    }

    /// Cherche un ou plusieurs symboles tradables Yahoo correspondant à une
    /// query (ISIN, ticker, nom d'actif). Retourne les 3 premiers résultats
    /// pour permettre des fallbacks (ex: même ETF coté sur 2 exchanges).
    private func searchYahooSymbols(query: String, isin: String?) async -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=10") else {
            return []
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
            // Si on a un ISIN, on privilégie les quotes qui matchent l'ISIN
            // exactement (Yahoo le renvoie quand il est connu)
            var ordered = decoded.quotes
            if let isin {
                let matching = ordered.filter { $0.isin?.uppercased() == isin.uppercased() }
                let others = ordered.filter { $0.isin?.uppercased() != isin.uppercased() }
                ordered = matching + others
            }
            // Prendre les 3 premiers symboles non-vides, dédupliqués
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
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
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

        // Mappings exchCode OpenFIGI/Bloomberg → suffixe Yahoo Finance.
        // Tableau exhaustif des marchés européens + crypto + US majeurs où
        // un suffixe est nécessaire côté Yahoo.
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
        // Suède / Nordics
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
            // Si le base contient déjà le suffix (ex: "EUEA.AS"), Yahoo
            // se débrouille — on l'ajoute aussi sans risque.
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
        // range=10y : couvre l'historique complet d'un PEA typique (ouvert il
        //   y a 5-10 ans en moyenne). Donne ~2520 points quotidiens — gros
        //   par rapport à 1y mais l'UPSERT v32 garantit zéro doublon en base.
        // interval=1d : précision quotidienne nécessaire pour les ranges
        //   courts (1J, 1S, 1M) qui sinon afficheraient une ligne quasi vide.
        //
        // Coût stockage : ~2520 points × 50 positions ≈ 126k rows = qqs MB
        // en SQLite. Largement acceptable.
        //
        // Si une position est plus ancienne que 10y, le chart "Max" sera
        // tronqué à 10y. Cas marginal (PEA ouvert avant 2015) — on s'en
        // occupera si le besoin remonte.
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=10y&interval=1d") else {
            return []
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first,
              let timestamps = result.timestamp,
              let quotes = result.indicators.quote.first?.close,
              !timestamps.isEmpty else { return [] }

        var points: [InvestmentPricePoint] = []
        for (idx, ts) in timestamps.enumerated() {
            guard idx < quotes.count, let close = quotes[idx], close > 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            points.append(InvestmentPricePoint(
                id: "\(symbol)-\(Int(ts))",
                identifier: symbol,
                date: date,
                close: close
            ))
        }
        return points.sorted { $0.date < $1.date }
    }

    private func fetchFromStooq(symbol: String) async throws -> [InvestmentPricePoint] {
        let sym = symbol.lowercased()
        guard let url = URL(string: "https://stooq.com/q/d/l/?s=\(sym)&i=d") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let csv = String(data: data, encoding: .utf8) else { return [] }

        let lines = csv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var points: [InvestmentPricePoint] = []
        for line in lines {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 5,
                  let date = isoDateFormatter.date(from: cols[0]),
                  let close = Double(cols[4]), close > 0 else { continue }
            points.append(InvestmentPricePoint(
                id: "\(symbol)-\(cols[0])",
                identifier: symbol,
                date: date,
                close: close
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
