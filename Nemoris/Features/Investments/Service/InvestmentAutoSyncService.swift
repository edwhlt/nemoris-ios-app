import Foundation
import Observation

// MARK: - Investment portfolio auto-sync
//
// Central orchestrator of the Investments sync:
//   1. LiveSync (Binance / EVM / BTC / Solana) via LiveSyncRegistry.syncAll()
//   2. Price history for every "stale" position (last cached point ≠ today),
//      sequential, with pacing handled by ProviderRateLimiter.
//
// Triggers: the app coming to the foreground (`.appActive`), opening the
// module (`.investmentsOpened`) — gated by 4 h + a user toggle — and
// pull-to-refresh (`.pullToRefresh`, bypasses the interval).
//
// `syncHistory(identifier:)` lives here too, WITHOUT any `load()`: reloading
// every view model per position would make a pass O(N²) on the main thread.
// The UI refresh goes through ONE `.nemorisInvestmentsDidSync` notification
// posted at the end of the pass (→ bumps AppState.dataRefreshToken in NemorisApp).

@Observable
@MainActor
final class InvestmentAutoSyncService {

    static let shared = InvestmentAutoSyncService()

    // MARK: - Observable state (UI hooks)

    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    /// Summary of the last pass (e.g. "12 prices up to date · 2 without data · Yahoo limited").
    /// `LocalizedStringResource`, not `String` — otherwise frozen in the language
    /// active AT SYNC TIME (see `InvestmentSyncTraceStore.Entry.message`).
    private(set) var lastSummary: LocalizedStringResource?
    /// True if the last pass hit at least one problem (computed once in
    /// `buildSummary`, see `SyncSummary.hasIssues`) — not a substring test on
    /// `lastSummary`, which would break as soon as the app isn't in French.
    private(set) var lastSyncHadIssues = false
    /// Typed outcome per identifier (uppercased key) — consumed by the views to
    /// show a per-position status without parsing messages.
    private(set) var outcomesByIdentifier: [String: PositionSyncOutcome] = [:]

    /// Records an outcome for `identifier` by hand. `syncNow()` (full pass) writes
    /// directly into `outcomesByIdentifier`; targeted syncs (account, position —
    /// `syncHistory(identifier:)` called outside a full pass) go through here, so
    /// the "?" stays an up-to-date view whatever the trigger, rather than a second,
    /// diverging tracking per screen.
    func recordOutcome(identifier: String, outcome: PositionSyncOutcome) {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        outcomesByIdentifier[key] = outcome
    }
    /// Progress of the current pass (nil outside a sync).
    private(set) var progress: SyncProgress?

    struct SyncProgress: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    enum Trigger {
        case appActive
        case investmentsOpened
        case pullToRefresh
    }

    // MARK: - Dependencies & keys

    private let repository = InvestmentRepository()
    private let marketDataService = InvestmentMarketDataService()

    private static let lastSyncKey = "investments.lastAutoSyncAt"
    private static let autoSyncEnabledKey = "investments.autoSyncEnabled"
    /// Minimum interval between 2 automatic passes.
    private static let minAutoSyncInterval: TimeInterval = 4 * 3600

    private init() {
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    /// User toggle "Automatic price sync" — defaults to TRUE (a missing key means
    /// enabled, see AppState.investmentsAutoSyncEnabled).
    static var autoSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: autoSyncEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: autoSyncEnabledKey)
    }

    // MARK: - Gated trigger

    /// Runs a full pass if every gate passes:
    ///   - Investments module enabled (feature flag)
    ///   - auto-sync toggle enabled
    ///   - no pass already running
    ///   - ≥ 4 h since the last pass (bypassed by `.pullToRefresh`)
    func autoSyncIfNeeded(trigger: Trigger) async {
        guard UserDefaults.standard.bool(forKey: "featureInvestments") else { return }
        guard Self.autoSyncEnabled else { return }
        guard !isSyncing else { return }
        if trigger != .pullToRefresh,
           let last = lastSyncAt,
           Date().timeIntervalSince(last) < Self.minAutoSyncInterval {
            return
        }
        await syncNow()
    }

    // MARK: - Full pass

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            progress = nil
            // ALWAYS posted, even on partial failure — it's what triggers the UI
            // reload (bumps dataRefreshToken).
            NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
        }
        print("[InvestmentAutoSyncService] Passe de sync démarrée")

        // 1. LiveSync exchanges/wallets (sequential, rate limits handled by the providers)
        // Pro feature (`.investmentsLiveSync`): a link created during a Pro period
        // must not keep syncing for free after cancellation — the management screen
        // (LiveSyncSettingsView) is locked by its own `paywallOverlay`, and this
        // background trigger must be too. The rest of the pass (price history of
        // manually entered positions) has nothing to do with Live Sync and carries
        // on for everyone.
        let liveSyncResults = PurchaseManager.shared.isUnlocked(.investmentsLiveSync)
            ? await LiveSyncRegistry.shared.syncAll()
            : []
        let liveSyncErrors = liveSyncResults.filter { $0.error != nil }

        // 2. Market history: targets = positions deduplicated by sync identifier
        //    (2 positions with the same ticker → a single fetch).
        let accounts = repository.fetchAccounts()
        let allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }

        var seen = Set<String>()
        var targets: [(identifier: String, isCrypto: Bool)] = []
        for position in allPositions {
            let identifier = position.bestSyncIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, seen.insert(identifier.uppercased()).inserted else { continue }
            targets.append((identifier, PriceResolver.coinId(forTicker: identifier) != nil))
        }

        outcomesByIdentifier = [:]
        progress = SyncProgress(done: 0, total: targets.count)

        // Provider families already rate-limited during THIS pass: crypto →
        // coinGecko; traditional securities → yahoo/stooq (grouped under .yahoo).
        // Remaining positions of the same family are marked .rateLimited WITHOUT
        // being tried — but the other family carries on.
        var rateLimitedFamilies = Set<MarketDataProvider>()
        var done = 0

        for target in targets {
            let key = target.identifier.uppercased()

            // Weekend refinement: traditional markets are closed Saturday/Sunday, so a
            // last point dated Friday is the most that can be reached → .upToDate
            // without a network call. Does NOT apply to cryptos (24/7).
            if !target.isCrypto,
               let latest = PriceHistoryCache.shared.latestDate(identifier: target.identifier),
               Self.isWeekendFresh(latest: latest) {
                outcomesByIdentifier[key] = .upToDate
                done += 1
                progress = SyncProgress(done: done, total: targets.count)
                continue
            }

            let family: MarketDataProvider = target.isCrypto ? .coinGecko : .yahoo
            if rateLimitedFamilies.contains(family) {
                let remaining = await ProviderRateLimiter.shared.cooldownRemaining(family)
                    ?? family.defaultCooldown
                outcomesByIdentifier[key] = .rateLimited(provider: family, retryAfter: remaining)
                done += 1
                progress = SyncProgress(done: done, total: targets.count)
                continue
            }

            let outcome = await syncHistory(identifier: target.identifier)
            outcomesByIdentifier[key] = outcome
            if case .rateLimited(let provider, _) = outcome {
                rateLimitedFamilies.insert(provider == .coinGecko ? .coinGecko : .yahoo)
            }

            done += 1
            progress = SyncProgress(done: done, total: targets.count)
            // Let the main actor breathe between 2 positions (smooth UI).
            await Task.yield()
        }

        // 3. Summary + persisting the date
        let summary = Self.buildSummary(
            outcomes: Array(outcomesByIdentifier.values),
            liveSyncTotal: liveSyncResults.count,
            liveSyncErrors: liveSyncErrors.count
        )
        lastSummary = summary.text
        lastSyncHadIssues = summary.hasIssues
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt, forKey: Self.lastSyncKey)
        print("[InvestmentAutoSyncService] Passe terminée — \(String(localized: summary.text))")
    }

    // MARK: - Syncing one identifier

    /// Syncs ONE identifier's (ticker/ISIN) price history: crypto → CoinGecko,
    /// otherwise Yahoo/Stooq. Skipped if the cache already has a point for today.
    /// Persists (disk cache + SQLite current_value + trace) but reloads NO view
    /// model: the caller does a SINGLE reload at the end of the pass.
    func syncHistory(identifier: String) async -> PositionSyncOutcome {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            InvestmentSyncTraceStore.record(.init(
                identifier: identifier, attemptedAt: Date(), status: .invalidId,
                message: LocalizedStringResource("Identifiant manquant (ticker/ISIN)."),
                symbolsTried: [], source: nil, pointsCount: 0
            ))
            return .invalidIdentifier
        }

        // Critical routing: a known crypto ticker → CoinGecko (otherwise Yahoo
        // quotes same-named stocks — the "FET" stock trading at €53 would corrupt
        // the Fetch.AI price, worth €1.50).
        if let coinId = PriceResolver.coinId(forTicker: clean) {
            return await syncCryptoHistory(identifier: clean, coinId: coinId)
        }

        // Skip optimization (Yahoo): the past is immutable. With a point for today
        // already cached, the API has nothing new to say.
        if let latest = PriceHistoryCache.shared.latestDate(identifier: clean),
           Calendar.current.isDateInToday(latest) {
            InvestmentSyncTraceStore.record(.init(
                identifier: clean, attemptedAt: Date(), status: .success,
                message: LocalizedStringResource("Cours déjà à jour (dernier point aujourd'hui) — appel Yahoo évité."),
                symbolsTried: [clean], source: "cache", pointsCount: 0
            ))
            return .upToDate
        }

        do {
            let result = try await marketDataService.fetchHistory(identifier: clean)
            _ = repository.savePriceHistory(identifier: clean, points: result.points, source: result.source)

            // Update current_value of the positions matching the identifier AND the
            // fetched result (which may differ after OpenFIGI resolution).
            let touchedA = repository.updatePositionsCurrentValueFromLatestPrice(identifier: result.identifier)
            let touchedB = result.identifier.uppercased() == clean.uppercased()
                ? 0
                : repository.updatePositionsCurrentValueFromLatestPrice(identifier: clean)
            let totalTouched = touchedA + touchedB

            // A `LocalizedStringResource` nests inside another through interpolation —
            // that's what allows composing a sentence in two parts without ever
            // freezing resolved text.
            let baseMsg = LocalizedStringResource("Historique synchronisé via \(result.source) (\(result.points.count) points).")
            let msg: LocalizedStringResource = totalTouched > 0
                ? LocalizedStringResource("\(baseMsg) \(totalTouched) position(s) mise(s) à jour.")
                : baseMsg

            // Persistent trace: ALL symbols tried (not just the winner), to show the
            // full resolution path.
            InvestmentSyncTraceStore.record(.init(
                identifier: clean, attemptedAt: Date(), status: .success,
                message: msg, symbolsTried: result.attemptedSymbols,
                source: result.source, pointsCount: result.points.count
            ))
            if result.identifier.uppercased() != clean.uppercased() {
                InvestmentSyncTraceStore.record(.init(
                    identifier: result.identifier, attemptedAt: Date(), status: .success,
                    message: msg, symbolsTried: result.attemptedSymbols,
                    source: result.source, pointsCount: result.points.count
                ))
            }
            return .success(points: result.points.count, source: result.source)
        } catch let error as InvestmentMarketDataError {
            switch error {
            case .invalidIdentifier:
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .invalidId,
                    message: LocalizedStringResource("\(error.localizedDescription)"),
                    symbolsTried: [clean], source: nil, pointsCount: 0
                ))
                return .invalidIdentifier
            case .noData(let symbols):
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .noData,
                    message: LocalizedStringResource("\(error.localizedDescription)"),
                    symbolsTried: symbols.isEmpty ? [clean] : symbols,
                    source: nil, pointsCount: 0
                ))
                return .noData(symbolsTried: symbols)
            case .rateLimited(let provider, let retryAfter):
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .rateLimited,
                    message: LocalizedStringResource("\(error.localizedDescription)"),
                    symbolsTried: [clean], source: nil, pointsCount: 0
                ))
                return .rateLimited(provider: provider, retryAfter: retryAfter)
            }
        } catch let error as MarketDataFetchError {
            // Can surface if the service lets a raw transport error leak.
            switch error {
            case .rateLimited(let provider, let retryAfter):
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .rateLimited,
                    message: LocalizedStringResource("Limite de requêtes \(provider.displayName) atteinte."),
                    symbolsTried: [clean], source: nil, pointsCount: 0
                ))
                return .rateLimited(provider: provider, retryAfter: retryAfter)
            case .timeout:
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .error,
                    message: LocalizedStringResource("Délai réseau dépassé."),
                    symbolsTried: [clean], source: nil, pointsCount: 0
                ))
                return .networkError("Délai réseau dépassé.")
            case .network(let message):
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .error,
                    message: LocalizedStringResource("Erreur réseau : \(message)"),
                    symbolsTried: [clean], source: nil, pointsCount: 0
                ))
                return .networkError(message)
            case .badStatus(let code):
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .error,
                    message: LocalizedStringResource("HTTP \(code)"),
                    symbolsTried: [clean], source: nil, pointsCount: 0
                ))
                return .networkError("HTTP \(code)")
            }
        } catch {
            InvestmentSyncTraceStore.record(.init(
                identifier: clean, attemptedAt: Date(), status: .error,
                message: LocalizedStringResource("\(error.localizedDescription)"),
                symbolsTried: [clean], source: nil, pointsCount: 0
            ))
            return .networkError(error.localizedDescription)
        }
    }

    /// Syncs a crypto's history via CoinGecko (without `load()`).
    private func syncCryptoHistory(identifier: String, coinId: String) async -> PositionSyncOutcome {
        // Skip optimization: already a point for today → no quota burned.
        if let latest = PriceHistoryCache.shared.latestDate(identifier: identifier),
           Calendar.current.isDateInToday(latest) {
            InvestmentSyncTraceStore.record(.init(
                identifier: identifier, attemptedAt: Date(), status: .success,
                message: LocalizedStringResource("Cours déjà à jour (dernier point aujourd'hui) — appel CoinGecko évité."),
                symbolsTried: [coinId], source: "cache", pointsCount: 0
            ))
            return .upToDate
        }

        let result = await PriceResolver.shared.fetchHistoryDetailed(
            coinId: coinId, identifier: identifier
        )
        guard !result.points.isEmpty else {
            if result.isRateLimited {
                let remaining = await ProviderRateLimiter.shared.cooldownRemaining(.coinGecko)
                    ?? MarketDataProvider.coinGecko.defaultCooldown
                InvestmentSyncTraceStore.record(.init(
                    identifier: identifier, attemptedAt: Date(), status: .rateLimited,
                    message: LocalizedStringResource("CoinGecko : limite de requêtes atteinte — réessai dans \(Int(remaining))s (coinId \(coinId))."),
                    symbolsTried: [coinId], source: nil, pointsCount: 0
                ))
                return .rateLimited(provider: .coinGecko, retryAfter: remaining)
            }
            let reason: LocalizedStringResource = result.errorReason.map { LocalizedStringResource(stringLiteral: $0) } ?? LocalizedStringResource("raison inconnue")
            InvestmentSyncTraceStore.record(.init(
                identifier: identifier, attemptedAt: Date(), status: .noData,
                message: LocalizedStringResource("CoinGecko : \(reason) (coinId \(coinId))."),
                symbolsTried: [coinId], source: nil, pointsCount: 0
            ))
            return .noData(symbolsTried: [coinId])
        }

        _ = repository.savePriceHistory(identifier: identifier, points: result.points, source: "coingecko")
        let touched = repository.updatePositionsCurrentValueFromLatestPrice(identifier: identifier)

        let baseCryptoMsg = LocalizedStringResource("Historique synchronisé via coingecko (\(result.points.count) points).")
        let msg: LocalizedStringResource = touched > 0
            ? LocalizedStringResource("\(baseCryptoMsg) \(touched) position(s) mise(s) à jour.")
            : baseCryptoMsg
        InvestmentSyncTraceStore.record(.init(
            identifier: identifier, attemptedAt: Date(), status: .success,
            message: msg, symbolsTried: [coinId, identifier],
            source: "coingecko", pointsCount: result.points.count
        ))
        return .success(points: result.points.count, source: "coingecko")
    }

    // MARK: - Intraday (1D range — 30-min points over a rolling 24-48 h)

    /// Syncs an identifier's INTRADAY history, triggered when the user selects the
    /// 1D range. Frequency matches the range: 30-min points, short retention
    /// (auto-purged by the cache) — the 10-year daily series stays the reference
    /// for every other range.
    /// Skipped if the last intraday point is less than 25 min old (freshness ≈ step).
    func syncIntradayHistory(identifier: String) async -> PositionSyncOutcome {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .invalidIdentifier }

        if let latest = PriceHistoryCache.shared.latestDate(identifier: clean, resolution: .intraday30m),
           Date().timeIntervalSince(latest) < 25 * 60 {
            return .upToDate
        }

        // Crypto → CoinGecko days=1 (downsampled to 30 min).
        if let coinId = PriceResolver.coinId(forTicker: clean) {
            let result = await PriceResolver.shared.fetchIntradayDetailed(coinId: coinId, identifier: clean)
            guard !result.points.isEmpty else {
                if result.isRateLimited {
                    let remaining = await ProviderRateLimiter.shared.cooldownRemaining(.coinGecko)
                        ?? MarketDataProvider.coinGecko.defaultCooldown
                    return .rateLimited(provider: .coinGecko, retryAfter: remaining)
                }
                return .noData(symbolsTried: [coinId])
            }
            PriceHistoryCache.shared.save(identifier: clean, points: result.points, resolution: .intraday30m)
            return .success(points: result.points.count, source: "coingecko")
        }

        // Traditional securities → Yahoo interval=30m, with the symbol ALREADY
        // RESOLVED by the daily sync: daily points carry the winning symbol in
        // their `identifier` field (e.g. ISIN → "EWLD.PA"). No OpenFIGI
        // re-resolution here.
        //
        // SEVERAL candidates, not just one. The symbol carried by the daily points
        // may not be queryable intraday (a series that came from Stooq, or an empty
        // daily cache → falling back to the ISIN, which Yahoo doesn't know and
        // answers with a 404). A single failed attempt would mean no 1D view,
        // silently.
        var candidates: [String] = []
        func addCandidate(_ value: String?) {
            guard let value, !value.isEmpty,
                  !candidates.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
            else { return }
            candidates.append(value)
        }
        addCandidate(PriceHistoryCache.shared.fetch(identifier: clean).last?.identifier)
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: [clean]), trace.status == .success {
            trace.symbolsTried.forEach(addCandidate)
        }
        addCandidate(clean)

        var lastOutcome: PositionSyncOutcome = .noData(symbolsTried: candidates)
        for symbol in candidates {
            do {
                let points = try await marketDataService.fetchIntradayHistory(symbol: symbol)
                guard !points.isEmpty else { continue }
                PriceHistoryCache.shared.save(identifier: clean, points: points, resolution: .intraday30m)
                InvestmentSyncTraceStore.record(.init(
                    identifier: clean, attemptedAt: Date(), status: .success,
                    message: LocalizedStringResource("Cours intrajournaliers synchronisés via yahoo (\(points.count) points, pas de 30 min)."),
                    symbolsTried: candidates, source: "yahoo", pointsCount: points.count
                ))
                return .success(points: points.count, source: "yahoo")
            } catch MarketDataFetchError.rateLimited(let provider, let retryAfter) {
                // No point trying the other symbols: the breaker is open for the whole
                // provider.
                lastOutcome = .rateLimited(provider: provider, retryAfter: retryAfter)
                break
            } catch {
                lastOutcome = .networkError(error.localizedDescription)
                continue
            }
        }

        // Persistent trace, like the daily pass: without it, the "Last price sync"
        // card couldn't say anything about a 1D failure.
        InvestmentSyncTraceStore.record(.init(
            identifier: clean, attemptedAt: Date(),
            status: {
                if case .rateLimited = lastOutcome { return .rateLimited }
                if case .networkError = lastOutcome { return .error }
                return .noData
            }(),
            // No `+`: `LocalizedStringResource` doesn't concatenate like `String`/`Text`
            // — each branch composes its own complete resource (nesting is supported),
            // starting from the same prefix.
            message: {
                let prefix = LocalizedStringResource("Cours intrajournaliers (1J) indisponibles.")
                switch lastOutcome {
                case .rateLimited(let provider, let retryAfter):
                    return LocalizedStringResource("\(prefix) \(provider.displayName) limite les requêtes — réessai dans \(Int(retryAfter)) s.")
                case .networkError(let message):
                    return LocalizedStringResource("\(prefix) \(message)")
                default:
                    return LocalizedStringResource("\(prefix) Aucun point 30 min renvoyé pour ce titre.")
                }
            }(),
            symbolsTried: candidates, source: nil, pointsCount: 0
        ))
        return lastOutcome
    }

    /// Sequential intraday sync of a batch of identifiers (tap on the 1D chip of
    /// the dashboard or of an account). Same policy as the daily pass: the whole
    /// provider family is skipped as soon as it's rate-limited.
    func syncIntradayIfNeeded(identifiers: [String]) async {
        var seen = Set<String>()
        var rateLimitedFamilies = Set<MarketDataProvider>()
        for identifier in identifiers {
            let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean.uppercased()).inserted else { continue }
            let family: MarketDataProvider = PriceResolver.coinId(forTicker: clean) != nil ? .coinGecko : .yahoo
            guard !rateLimitedFamilies.contains(family) else { continue }
            let outcome = await syncIntradayHistory(identifier: clean)
            if case .rateLimited(let provider, _) = outcome {
                rateLimitedFamilies.insert(provider)
            }
            await Task.yield()
        }
    }

    // MARK: - Helpers

    /// True if `latest` is the last quote reachable over a weekend: last point =
    /// Friday OF THIS weekend, today = Saturday or Sunday. Traditional markets are
    /// closed → nothing to fetch.
    private static func isWeekendFresh(latest: Date) -> Bool {
        let calendar = Calendar.current
        let todayWeekday = calendar.component(.weekday, from: Date())
        // Gregorian: 1 = Sunday, 6 = Friday, 7 = Saturday.
        guard todayWeekday == 1 || todayWeekday == 7 else { return false }
        guard calendar.component(.weekday, from: latest) == 6 else { return false }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latest),
            to: calendar.startOfDay(for: Date())
        ).day ?? .max
        return days <= 2
    }

    /// `hasIssues` lets the view (`InvestmentsView`) avoid testing the summary
    /// text for words — a text now resolved in the app's language, so matching
    /// French words breaks as soon as the app runs in English. Computed here,
    /// once, from the same counters as the text — not a second, diverging reading.
    struct SyncSummary {
        let text: LocalizedStringResource
        let hasIssues: Bool
    }

    private static func buildSummary(
        outcomes: [PositionSyncOutcome],
        liveSyncTotal: Int,
        liveSyncErrors: Int
    ) -> SyncSummary {
        var synced = 0, upToDate = 0, noData = 0, invalid = 0, netErrors = 0
        var limitedProviders = Set<String>()
        for outcome in outcomes {
            switch outcome {
            case .success:                       synced += 1
            case .upToDate:                      upToDate += 1
            case .noData:                        noData += 1
            case .invalidIdentifier:             invalid += 1
            case .networkError:                  netErrors += 1
            case .rateLimited(let provider, _):  limitedProviders.insert(provider.displayName)
            }
        }
        let hasIssues = noData > 0 || invalid > 0 || netErrors > 0
            || !limitedProviders.isEmpty || liveSyncErrors > 0

        // `LocalizedStringResource` doesn't conform to `Sequence.joined()` — manual
        // fold by nesting (supported), which keeps each fragment's key + arguments
        // instead of freezing text.
        var parts: [LocalizedStringResource] = []
        if synced > 0    { parts.append(LocalizedStringResource("\(synced) cours synchronisé\(synced > 1 ? "s" : "")")) }
        if upToDate > 0  { parts.append(LocalizedStringResource("\(upToDate) à jour")) }
        if noData > 0    { parts.append(LocalizedStringResource("\(noData) sans données")) }
        if invalid > 0   { parts.append(LocalizedStringResource("\(invalid) sans identifiant")) }
        if netErrors > 0 { parts.append(LocalizedStringResource("\(netErrors) erreur\(netErrors > 1 ? "s" : "") réseau")) }
        if !limitedProviders.isEmpty {
            parts.append(LocalizedStringResource("\(limitedProviders.sorted().joined(separator: " + ")) limité"))
        }
        if liveSyncErrors > 0 {
            parts.append(LocalizedStringResource("\(liveSyncErrors)/\(liveSyncTotal) LiveSync en erreur"))
        } else if liveSyncTotal > 0 {
            parts.append(LocalizedStringResource("\(liveSyncTotal) LiveSync OK"))
        }
        guard let first = parts.first else {
            return SyncSummary(text: LocalizedStringResource("Rien à synchroniser"), hasIssues: false)
        }
        let text = parts.dropFirst().reduce(first) { acc, part in
            LocalizedStringResource("\(acc) · \(part)")
        }
        return SyncSummary(text: text, hasIssues: hasIssues)
    }
}
