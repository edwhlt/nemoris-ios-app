import Foundation

// MARK: - Chantier A — Résilience des fetchs de cours (rate-limiting, retries, outcomes typés)
//
// Couche transverse utilisée par TOUS les appels réseau "données de marché" :
//   - InvestmentMarketDataService (Yahoo chart/search, Stooq CSV, OpenFIGI POST)
//   - PriceResolver (CoinGecko market_chart)
//
// 3 briques :
//   1. `ProviderRateLimiter` (actor) — pacing entre 2 requêtes d'un même provider
//      + circuit breaker après un 429 (cooldown pendant lequel AUCUN appel ne part).
//   2. `ResilientHTTP` — GET/POST avec timeout court, retry backoff exponentiel
//      + jitter sur 5xx/erreurs réseau, typage propre du 429 (header Retry-After).
//   3. `PositionSyncOutcome` — résultat typé d'une sync de cours par position,
//      consommé par InvestmentAutoSyncService et les vues (fini le matching de
//      succès par sous-chaîne de message).

// MARK: - Providers de données de marché

/// Tout service HTTP tiers cadencé par `ProviderRateLimiter`.
///
/// ⚠️ S'appelait `MarketDataProvider` : le renommage accompagne l'arrivée de providers qui
/// n'ont rien de boursier (registre d'entreprises, référentiel des communes). Le pacing,
/// le disjoncteur 429 et le backoff sont exactement les mêmes besoins — d'où la
/// mutualisation plutôt qu'une seconde couche parallèle. `typealias` conservé une version.
enum RemoteProvider: String, Sendable, CaseIterable {
    case yahoo
    case stooq
    case openFIGI
    case coinGecko
    /// recherche-entreprises.api.gouv.fr — ~7 req/s d'après la doc gouv.
    case sireneGouv
    /// geo.api.gouv.fr — référentiel des communes, sans clé.
    case geoGouv

    /// Délai minimal entre 2 requêtes vers le même provider (pacing).
    var minInterval: TimeInterval {
        switch self {
        case .yahoo:      return 0.4
        case .stooq:      return 0.5
        case .openFIGI:   return 2.5   // 25 req/min sans clé API
        case .coinGecko:  return 2.2   // ~30 req/min free tier
        case .sireneGouv: return 0.15  // 7 req/s
        case .geoGouv:    return 0.1
        }
    }

    /// Durée du circuit breaker après un 429 sans header Retry-After.
    var defaultCooldown: TimeInterval {
        switch self {
        case .yahoo:      return 120
        case .coinGecko:  return 65
        case .openFIGI:   return 65
        case .stooq:      return 60
        case .sireneGouv: return 30
        case .geoGouv:    return 30
        }
    }

    /// Nom affichable dans les messages utilisateur (FR).
    var displayName: String {
        switch self {
        case .yahoo:      return "Yahoo"
        case .stooq:      return "Stooq"
        case .openFIGI:   return "OpenFIGI"
        case .coinGecko:  return "CoinGecko"
        case .sireneGouv: return "Annuaire des entreprises"
        case .geoGouv:    return "Référentiel des communes"
        }
    }
}

/// Compatibilité descendante — à retirer une fois les appelants migrés.
typealias MarketDataProvider = RemoteProvider

// MARK: - Erreurs typées

enum MarketDataFetchError: Error, Sendable {
    /// Le provider a renvoyé un 429 (ou son breaker est encore ouvert).
    /// `retryAfter` = secondes restantes avant la prochaine tentative possible.
    case rateLimited(provider: MarketDataProvider, retryAfter: TimeInterval)
    case timeout
    case network(String)
    case badStatus(Int)
}

// MARK: - Rate limiter / circuit breaker par provider

/// Sérialise les requêtes par provider (pacing `minInterval`) et ouvre un
/// circuit breaker après un 429 : tant que le cooldown court, `waitTurn` throw
/// immédiatement SANS appel réseau — les appelants savent typologiquement
/// qu'ils sont limités et depuis combien de temps.
actor ProviderRateLimiter {

    static let shared = ProviderRateLimiter()
    private init() {}

    /// Date du dernier slot de requête RÉSERVÉ par provider (pas forcément
    /// déjà exécuté : le slot est posé avant le sleep pour que 2 tasks
    /// concurrentes ne prennent pas le même créneau).
    private var lastRequestAt: [MarketDataProvider: Date] = [:]
    /// Breaker : aucun appel vers ce provider avant cette date.
    private var cooldownUntil: [MarketDataProvider: Date] = [:]

    /// Attend son tour pour `provider`. Throw `.rateLimited` immédiatement si
    /// le breaker est ouvert (aucun appel réseau ne doit partir).
    func waitTurn(_ provider: MarketDataProvider) async throws {
        if let until = cooldownUntil[provider] {
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 {
                throw MarketDataFetchError.rateLimited(provider: provider, retryAfter: remaining)
            }
            cooldownUntil[provider] = nil
        }

        // Réservation atomique du slot AVANT le sleep : le prochain appelant
        // calculera son créneau après le nôtre (pas de double-booking).
        let now = Date()
        let earliest: Date
        if let last = lastRequestAt[provider] {
            earliest = max(last.addingTimeInterval(provider.minInterval), now)
        } else {
            earliest = now
        }
        lastRequestAt[provider] = earliest

        let wait = earliest.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Ouvre le breaker suite à un 429. `retryAfter` = valeur du header
    /// Retry-After si le provider l'a fournie, sinon cooldown par défaut.
    func reportRateLimited(_ provider: MarketDataProvider, retryAfter: TimeInterval?) {
        let cooldown = retryAfter ?? provider.defaultCooldown
        cooldownUntil[provider] = Date().addingTimeInterval(cooldown)
        print("[ProviderRateLimiter] \(provider.rawValue) limité (429) — breaker ouvert \(Int(cooldown))s")
    }

    /// Secondes restantes de cooldown pour `provider`, nil si le breaker est fermé.
    func cooldownRemaining(_ provider: MarketDataProvider) -> TimeInterval? {
        guard let until = cooldownUntil[provider] else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }
}

// MARK: - HTTP résilient

/// Wrapper URLSession commun aux fetchs de cours :
///   waitTurn (pacing/breaker) → requête timeout court → gestion typée du 429
///   (Retry-After) → retry backoff expo + jitter sur 5xx / timeouts réseau.
/// Les 4xx (hors 429) ne sont PAS retentés (échec déterministe).
enum ResilientHTTP {

    static func get(
        _ url: URL,
        provider: MarketDataProvider,
        timeout: TimeInterval = 15,
        maxRetries: Int = 2
    ) async throws -> Data {
        let request = URLRequest(url: url)
        return try await send(request, provider: provider, timeout: timeout, maxRetries: maxRetries)
    }

    static func send(
        _ request: URLRequest,
        provider: MarketDataProvider,
        timeout: TimeInterval = 15,
        maxRetries: Int = 2
    ) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout

        var lastError: Error = MarketDataFetchError.network("Erreur inconnue")

        for attempt in 0...max(0, maxRetries) {
            // Breaker ouvert → throw .rateLimited immédiat, AUCUN appel réseau.
            try await ProviderRateLimiter.shared.waitTurn(provider)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    // Quasi impossible en HTTPS — échec non-retryable.
                    throw MarketDataFetchError.network("Réponse non-HTTP")
                }
                switch http.statusCode {
                case 200:
                    return data
                case 429:
                    let retryAfter = parseRetryAfter(http)
                    await ProviderRateLimiter.shared.reportRateLimited(provider, retryAfter: retryAfter)
                    throw MarketDataFetchError.rateLimited(
                        provider: provider,
                        retryAfter: retryAfter ?? provider.defaultCooldown
                    )
                case 500...599:
                    // Erreur serveur transitoire → retryable.
                    lastError = MarketDataFetchError.badStatus(http.statusCode)
                default:
                    // Autre 4xx (404 symbole inconnu, 401…) : déterministe, pas de retry.
                    throw MarketDataFetchError.badStatus(http.statusCode)
                }
            } catch let error as MarketDataFetchError {
                // rateLimited / badStatus 4xx / réponse non-HTTP : throw direct.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .timedOut {
                lastError = MarketDataFetchError.timeout
            } catch {
                // Autres erreurs réseau (connexion perdue, DNS…) → retryable.
                lastError = MarketDataFetchError.network(error.localizedDescription)
            }

            // Backoff expo + jitter avant la prochaine tentative :
            // 0.8 × 2^attempt + random(0…0.4) secondes.
            if attempt < maxRetries {
                let backoff = 0.8 * pow(2.0, Double(attempt)) + Double.random(in: 0...0.4)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }

        throw lastError
    }

    /// Parse le header `Retry-After` (format secondes uniquement — le format
    /// HTTP-date est ignoré, aucun de nos providers ne l'utilise).
    private static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), seconds > 0 else {
            return nil
        }
        return seconds
    }
}

// MARK: - Résultat typé d'une sync de cours par position

enum PositionSyncOutcome: Sendable, Equatable {
    case success(points: Int, source: String)
    /// Dernier point du cache = aujourd'hui (ou vendredi un week-end pour les
    /// titres traditionnels) — aucun appel réseau nécessaire.
    case upToDate
    case noData(symbolsTried: [String])
    case rateLimited(provider: MarketDataProvider, retryAfter: TimeInterval)
    case networkError(String)
    case invalidIdentifier

    /// Libellé court pour affichage compact (chips, lignes de statut).
    var shortLabel: LocalizedStringResource {
        switch self {
        case .success(let points, let source):
            return "\(points) points via \(source)"
        case .upToDate:
            return "À jour"
        case .noData:
            return "Aucune donnée"
        case .rateLimited(let provider, let retryAfter):
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "Limite \(provider.displayName) — réessai dans \(minutes) min"
        case .networkError:
            return "Erreur réseau"
        case .invalidIdentifier:
            return "Identifiant invalide"
        }
    }

    /// Vrai pour tout ce qui n'est pas un succès franc — sert à isoler les
    /// positions à surfacer dans le détail "?" (le reste est du bruit une fois
    /// qu'on sait que la passe a globalement marché).
    var isProblem: Bool {
        switch self {
        case .success, .upToDate: return false
        case .noData, .rateLimited, .networkError, .invalidIdentifier: return true
        }
    }

    var systemIcon: String {
        switch self {
        case .success:          return "checkmark.circle.fill"
        case .upToDate:         return "checkmark.circle"
        case .noData:           return "questionmark.circle.fill"
        case .rateLimited:      return "hourglass.circle.fill"
        case .networkError:     return "wifi.exclamationmark"
        case .invalidIdentifier: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Notification de fin de sync investissements

extension Notification.Name {
    /// Postée (main thread) après une passe de synchronisation investissements
    /// (LiveSync exchanges/wallets + historique des cours) — l'UI doit recharger.
    /// Observée dans NemorisApp → bump de AppState.dataRefreshToken.
    /// Miroir du pattern `nemorisSyncDidApplyRemoteChanges` (CloudSyncEngine).
    static let nemorisInvestmentsDidSync = Notification.Name("nemorisInvestmentsDidSync")
}
