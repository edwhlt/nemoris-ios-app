import Foundation
import Observation

// MARK: - Chantier A — Auto-sync des portefeuilles d'investissement
//
// Orchestrateur central de la synchronisation Investissements :
//   1. LiveSync (Binance / EVM / BTC / Solana) via LiveSyncRegistry.syncAll()
//   2. Historique des cours pour toutes les positions "stale" (dernier point
//      du cache ≠ aujourd'hui), séquentiel avec pacing géré par ProviderRateLimiter.
//
// Déclencheurs : passage de l'app en premier plan (`.appActive`), ouverture du
// module (`.investmentsOpened`) — gates 4 h + toggle user — et pull-to-refresh
// (`.pullToRefresh`, bypass de l'intervalle).
//
// C'est aussi ici que vit `syncHistory(identifier:)` — le corps déplacé de
// `InvestmentsViewModel.syncMarketHistory` / `syncCryptoHistory` — SANS AUCUN
// `load()` : le fix du O(N²) (avant : full reload SQLite main-thread PAR position).
// Le refresh UI passe par UNE notification `.nemorisInvestmentsDidSync` postée
// en fin de passe (→ bump de AppState.dataRefreshToken dans NemorisApp).

@Observable
@MainActor
final class InvestmentAutoSyncService {

    static let shared = InvestmentAutoSyncService()

    // MARK: - État observable (hooks UI)

    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    /// Résumé de la dernière passe (ex. "12 cours à jour · 2 sans données · Yahoo limité").
    /// ⚠️ `LocalizedStringResource`, pas `String` — sinon figé dans la langue
    /// active AU MOMENT DU SYNC (cf. `InvestmentSyncTraceStore.Entry.message`).
    private(set) var lastSummary: LocalizedStringResource?
    /// Vrai si la dernière passe a rencontré au moins un problème (calculé une
    /// fois dans `buildSummary`, cf. `SyncSummary.hasIssues`) — pas un test de
    /// sous-chaîne sur `lastSummary`, qui casserait dès que l'app n'est plus
    /// en français.
    private(set) var lastSyncHadIssues = false
    /// Outcome typé par identifier (clé uppercased) — consommé par les vues
    /// pour afficher un statut par position sans parser de messages.
    private(set) var outcomesByIdentifier: [String: PositionSyncOutcome] = [:]

    /// Enregistre manuellement un outcome pour `identifier`. `syncNow()` (passe
    /// complète) écrit directement dans `outcomesByIdentifier` ; les sync ciblées
    /// (compte, position — `syncHistory(identifier:)` appelé hors passe complète)
    /// passent par ici pour que le "?" reste une vue à jour quel que soit le
    /// déclencheur, plutôt qu'un 2ᵉ suivi divergent par écran.
    func recordOutcome(identifier: String, outcome: PositionSyncOutcome) {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        outcomesByIdentifier[key] = outcome
    }
    /// Progression de la passe courante (nil hors sync).
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

    // MARK: - Dépendances & clés

    private let repository = InvestmentRepository()
    private let marketDataService = InvestmentMarketDataService()

    private static let lastSyncKey = "investments.lastAutoSyncAt"
    private static let autoSyncEnabledKey = "investments.autoSyncEnabled"
    /// Intervalle minimal entre 2 passes automatiques.
    private static let minAutoSyncInterval: TimeInterval = 4 * 3600

    private init() {
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Toggle user "Synchronisation automatique des cours" — défaut TRUE
    /// (la clé absente vaut activé, cf. AppState.investmentsAutoSyncEnabled).
    static var autoSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: autoSyncEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: autoSyncEnabledKey)
    }

    // MARK: - Déclencheur gated

    /// Lance une passe complète si toutes les gates passent :
    ///   - module Investissements activé (feature flag)
    ///   - toggle auto-sync activé
    ///   - pas de passe déjà en cours
    ///   - ≥ 4 h depuis la dernière passe (bypassé par `.pullToRefresh`)
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

    // MARK: - Passe complète

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            progress = nil
            // TOUJOURS posté, même en cas d'échec partiel — c'est ce qui
            // déclenche le rechargement de l'UI (bump dataRefreshToken).
            NotificationCenter.default.post(name: .nemorisInvestmentsDidSync, object: nil)
        }
        print("[InvestmentAutoSyncService] Passe de sync démarrée")

        // 1. LiveSync exchanges/wallets (séquentiel, rate limits gérés côté providers)
        // Feature Pro (`.investmentsLiveSync`) : un lien créé pendant une période Pro
        // ne doit pas continuer à se synchroniser gratuitement après résiliation —
        // seul l'écran de gestion (LiveSyncSettingsView) est verrouillé par son
        // propre `paywallOverlay`, ce déclencheur en arrière-plan doit l'être aussi.
        // Le reste de la passe (historique de cours des positions saisies à la
        // main) n'a rien à voir avec Live Sync et continue pour tout le monde.
        let liveSyncResults = PurchaseManager.shared.isUnlocked(.investmentsLiveSync)
            ? await LiveSyncRegistry.shared.syncAll()
            : []
        let liveSyncErrors = liveSyncResults.filter { $0.error != nil }

        // 2. Historique marché : cibles = positions dédupliquées par identifier
        //    de sync (2 positions même ticker → 1 seul fetch).
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

        // Familles de providers déjà rate-limitées pendant CETTE passe :
        // crypto → coinGecko ; titres traditionnels → yahoo/stooq (regroupés
        // sous .yahoo). Les positions restantes de la même famille sont
        // marquées .rateLimited SANS être tentées — mais l'autre famille continue.
        var rateLimitedFamilies = Set<MarketDataProvider>()
        var done = 0

        for target in targets {
            let key = target.identifier.uppercased()

            // Raffinement week-end : marchés traditionnels fermés samedi/dimanche,
            // un dernier point daté de vendredi est le maximum atteignable →
            // .upToDate sans appel réseau. Ne s'applique PAS aux cryptos (24/7).
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
            // Laisse respirer le main actor entre 2 positions (UI fluide).
            await Task.yield()
        }

        // 3. Résumé + persistance de la date
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

    // MARK: - Sync d'un identifier (corps déplacé depuis InvestmentsViewModel)

    /// Synchronise l'historique de cours d'UN identifier (ticker/ISIN) :
    /// route crypto → CoinGecko, sinon Yahoo/Stooq. Skip si le cache a déjà
    /// un point aujourd'hui. Persiste (cache disque + current_value SQLite +
    /// trace) mais NE recharge AUCUN ViewModel — c'est le cœur du fix O(N²) :
    /// l'appelant fait UN SEUL reload en fin de passe.
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

        // Route critique : ticker crypto connu → CoinGecko (sinon Yahoo cote
        // des actions homonymes — l'action "FET" cotée €53 corromprait le
        // cours Fetch.AI qui vaut €1.50).
        if let coinId = PriceResolver.coinId(forTicker: clean) {
            return await syncCryptoHistory(identifier: clean, coinId: coinId)
        }

        // Skip optimization (Yahoo) : le passé est immuable. Si on a déjà un
        // point pour aujourd'hui en cache, l'API ne nous apprendra rien.
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

            // Update current_value des positions matchant l'identifier ET le
            // résultat fetché (qui peut différer après résolution OpenFIGI).
            let touchedA = repository.updatePositionsCurrentValueFromLatestPrice(identifier: result.identifier)
            let touchedB = result.identifier.uppercased() == clean.uppercased()
                ? 0
                : repository.updatePositionsCurrentValueFromLatestPrice(identifier: clean)
            let totalTouched = touchedA + touchedB

            // `LocalizedStringResource` s'imbrique dans un autre via
            // interpolation (vérifié) — c'est ce qui permet de composer une
            // phrase en deux morceaux sans jamais figer de texte résolu.
            let baseMsg = LocalizedStringResource("Historique synchronisé via \(result.source) (\(result.points.count) points).")
            let msg: LocalizedStringResource = totalTouched > 0
                ? LocalizedStringResource("\(baseMsg) \(totalTouched) position(s) mise(s) à jour.")
                : baseMsg

            // Trace persistante : TOUS les symboles essayés (pas seulement le
            // winner) pour montrer le chemin de résolution complet.
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
            // Peut remonter si le service laisse fuiter une erreur transport brute.
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

    /// Sync historique d'une crypto via CoinGecko (corps déplacé depuis
    /// `InvestmentsViewModel.syncCryptoHistory`, sans `load()`).
    private func syncCryptoHistory(identifier: String, coinId: String) async -> PositionSyncOutcome {
        // Skip optimization : déjà un point aujourd'hui → pas de quota brûlé.
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

    // MARK: - Intraday (plage 1J — points 30 min sur 24-48 h glissantes)

    /// Sync de l'historique INTRADAY d'un identifier, déclenchée quand l'utilisateur
    /// sélectionne la plage 1J. Adapte la fréquence à la plage : points 30 min,
    /// rétention 48 h (purge auto côté cache) — le quotidien 10 ans reste la
    /// série de référence pour toutes les autres plages.
    /// Skip si le dernier point intraday a moins de 25 min (fraîcheur ≈ pas).
    func syncIntradayHistory(identifier: String) async -> PositionSyncOutcome {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .invalidIdentifier }

        if let latest = PriceHistoryCache.shared.latestDate(identifier: clean, resolution: .intraday30m),
           Date().timeIntervalSince(latest) < 25 * 60 {
            return .upToDate
        }

        // Crypto → CoinGecko days=1 (sous-échantillonné 30 min).
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

        // Titres traditionnels → Yahoo interval=30m, avec le symbole DÉJÀ RÉSOLU
        // par la sync quotidienne : les points quotidiens portent le symbole
        // gagnant dans leur champ `identifier` (ex. ISIN → "EWLD.PA"). Pas de
        // re-résolution OpenFIGI ici.
        //
        // ⚠️ PLUSIEURS candidats, plus un seul. Le symbole porté par les points
        // quotidiens peut ne pas être interrogeable en intraday (série venue de
        // Stooq, ou cache quotidien vide → on retombait sur l'ISIN, que Yahoo
        // ne connaît pas et renvoie en 404). Un seul essai raté = pas de vue 1J,
        // silencieusement.
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
                // Inutile d'essayer les autres symboles : le breaker est ouvert
                // pour tout le provider.
                lastOutcome = .rateLimited(provider: provider, retryAfter: retryAfter)
                break
            } catch {
                lastOutcome = .networkError(error.localizedDescription)
                continue
            }
        }

        // Trace persistante, comme la passe quotidienne : sans elle, la carte
        // « Dernière synchro du cours » ne pouvait rien dire d'un échec 1J.
        InvestmentSyncTraceStore.record(.init(
            identifier: clean, attemptedAt: Date(),
            status: {
                if case .rateLimited = lastOutcome { return .rateLimited }
                if case .networkError = lastOutcome { return .error }
                return .noData
            }(),
            // Pas de `+` : `LocalizedStringResource` ne concatène pas comme
            // `String`/`Text` — chaque branche compose sa propre ressource
            // complète (imbrication testée et supportée), en partant du
            // même préfixe.
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

    /// Sync intraday séquentielle d'un lot d'identifiers (tap sur la chip 1J
    /// du dashboard ou d'un compte). Même politique que la passe quotidienne :
    /// skip de toute la famille de provider dès qu'elle est rate-limitée.
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

    /// True si `latest` est le dernier point de cotation atteignable un
    /// week-end : dernier point = vendredi DE CE week-end, aujourd'hui =
    /// samedi ou dimanche. Marchés traditionnels fermés → rien à fetcher.
    private static func isWeekendFresh(latest: Date) -> Bool {
        let calendar = Calendar.current
        let todayWeekday = calendar.component(.weekday, from: Date())
        // Grégorien : 1 = dimanche, 6 = vendredi, 7 = samedi.
        guard todayWeekday == 1 || todayWeekday == 7 else { return false }
        guard calendar.component(.weekday, from: latest) == 6 else { return false }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latest),
            to: calendar.startOfDay(for: Date())
        ).day ?? .max
        return days <= 2
    }

    /// `hasIssues` remplace un ancien test `summary.contains("erreur")` côté
    /// vue (`InvestmentsView`) — fragile car il matchait des MOTS FRANÇAIS
    /// dans un texte désormais résolu dans la langue de l'app : cassé dès que
    /// l'app tourne en anglais. Calculé ici, une seule fois, à partir des
    /// mêmes compteurs que le texte — pas une 2ᵉ lecture divergente.
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

        // `LocalizedStringResource` ne conforme pas à `Sequence.joined()` —
        // repli manuel par imbrication (testé, supporté), qui préserve la
        // clé + les arguments de chaque fragment au lieu de figer du texte.
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
