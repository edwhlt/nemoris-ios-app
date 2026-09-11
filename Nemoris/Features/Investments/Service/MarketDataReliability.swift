import Foundation

// MARK: - Resilience of price fetches (rate limiting, retries, typed outcomes)
//
// Cross-cutting layer used by EVERY "market data" network call:
//   - InvestmentMarketDataService (Yahoo chart/search, Stooq CSV, OpenFIGI POST)
//   - PriceResolver (CoinGecko market_chart)
//
// 3 building blocks:
//   1. `ProviderRateLimiter` (actor) — pacing between 2 requests to the same
//      provider + circuit breaker after a 429 (a cooldown during which NO call
//      goes out).
//   2. `ResilientHTTP` — GET/POST with a short timeout, exponential backoff
//      retry + jitter on 5xx/network errors, clean typing of the 429
//      (Retry-After header).
//   3. `PositionSyncOutcome` — typed result of a per-position price sync,
//      consumed by InvestmentAutoSyncService and the views (no matching of
//      success on a message substring).

// MARK: - Market data providers

/// Any third-party HTTP service paced by `ProviderRateLimiter`.
///
/// Covers providers that have nothing to do with markets too (company
/// registry, municipality reference): pacing, the 429 breaker and backoff are
/// exactly the same needs — hence one shared layer rather than a second,
/// parallel one.
enum RemoteProvider: String, Sendable, CaseIterable {
    case yahoo
    case stooq
    case openFIGI
    case coinGecko
    /// recherche-entreprises.api.gouv.fr — ~7 req/s according to the official docs.
    case sireneGouv
    /// geo.api.gouv.fr — municipality reference, no key.
    case geoGouv

    /// Minimum delay between 2 requests to the same provider (pacing).
    var minInterval: TimeInterval {
        switch self {
        case .yahoo:      return 0.4
        case .stooq:      return 0.5
        case .openFIGI:   return 2.5   // 25 req/min without an API key
        case .coinGecko:  return 2.2   // ~30 req/min free tier
        case .sireneGouv: return 0.15  // 7 req/s
        case .geoGouv:    return 0.1
        }
    }

    /// Circuit breaker duration after a 429 without a Retry-After header.
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

    /// Name displayed in user-facing messages.
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

/// Former name, kept for existing callers.
typealias MarketDataProvider = RemoteProvider

// MARK: - Typed errors

enum MarketDataFetchError: Error, Sendable {
    /// The provider returned a 429 (or its breaker is still open).
    /// `retryAfter` = seconds left before the next possible attempt.
    case rateLimited(provider: MarketDataProvider, retryAfter: TimeInterval)
    case timeout
    case network(String)
    case badStatus(Int)
}

// MARK: - Rate limiter / circuit breaker par provider

/// Serializes requests per provider (`minInterval` pacing) and opens a circuit
/// breaker after a 429: while the cooldown runs, `waitTurn` throws immediately
/// WITHOUT a network call — callers know, through the type, that they are
/// limited and for how long.
actor ProviderRateLimiter {

    static let shared = ProviderRateLimiter()
    private init() {}

    /// Date of the last request slot RESERVED per provider (not necessarily
    /// executed yet: the slot is set before the sleep so 2 concurrent tasks don't
    /// take the same slot).
    private var lastRequestAt: [MarketDataProvider: Date] = [:]
    /// Breaker: no call to this provider before this date.
    private var cooldownUntil: [MarketDataProvider: Date] = [:]

    /// Waits for its turn for `provider`. Throws `.rateLimited` immediately if
    /// the breaker is open (no network call must go out).
    func waitTurn(_ provider: MarketDataProvider) async throws {
        if let until = cooldownUntil[provider] {
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 {
                throw MarketDataFetchError.rateLimited(provider: provider, retryAfter: remaining)
            }
            cooldownUntil[provider] = nil
        }

        // Atomic slot reservation BEFORE the sleep: the next caller will compute its
        // slot after ours (no double booking).
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

    /// Opens the breaker after a 429. `retryAfter` = the Retry-After header value
    /// when the provider supplied it, otherwise the default cooldown.
    func reportRateLimited(_ provider: MarketDataProvider, retryAfter: TimeInterval?) {
        let cooldown = retryAfter ?? provider.defaultCooldown
        cooldownUntil[provider] = Date().addingTimeInterval(cooldown)
        print("[ProviderRateLimiter] \(provider.rawValue) limité (429) — breaker ouvert \(Int(cooldown))s")
    }

    /// Seconds of cooldown left for `provider`, nil if the breaker is closed.
    func cooldownRemaining(_ provider: MarketDataProvider) -> TimeInterval? {
        guard let until = cooldownUntil[provider] else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }
}

// MARK: - Resilient HTTP

/// URLSession wrapper shared by price fetches:
///   waitTurn (pacing/breaker) → short-timeout request → typed 429 handling
///   (Retry-After) → exponential backoff retry + jitter on 5xx / network timeouts.
/// 4xx (except 429) are NOT retried (deterministic failure).
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
            // Breaker open → throw .rateLimited immediately, NO network call.
            try await ProviderRateLimiter.shared.waitTurn(provider)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    // Nearly impossible over HTTPS — non-retryable failure.
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
                    // Other 4xx (404 unknown symbol, 401…): deterministic, no retry.
                    throw MarketDataFetchError.badStatus(http.statusCode)
                }
            } catch let error as MarketDataFetchError {
                // rateLimited / 4xx badStatus / non-HTTP response: throw directly.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .timedOut {
                lastError = MarketDataFetchError.timeout
            } catch {
                // Other network errors (connection lost, DNS…) → retryable.
                lastError = MarketDataFetchError.network(error.localizedDescription)
            }

            // Exponential backoff + jitter before the next attempt:
            // 0.8 × 2^attempt + random(0…0.4) seconds.
            if attempt < maxRetries {
                let backoff = 0.8 * pow(2.0, Double(attempt)) + Double.random(in: 0...0.4)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }

        throw lastError
    }

    /// Parses the `Retry-After` header (seconds format only — the HTTP-date
    /// format is ignored, none of our providers uses it).
    private static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), seconds > 0 else {
            return nil
        }
        return seconds
    }
}

// MARK: - Typed result of a per-position price sync

enum PositionSyncOutcome: Sendable, Equatable {
    case success(points: Int, source: String)
    /// The cache's last point = today (or Friday over a weekend for traditional
    /// securities) — no network call needed.
    case upToDate
    case noData(symbolsTried: [String])
    case rateLimited(provider: MarketDataProvider, retryAfter: TimeInterval)
    case networkError(String)
    case invalidIdentifier

    /// Short label for compact display (chips, status lines).
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

    /// True for anything that isn't a clear success — isolates the positions to
    /// surface in the "?" detail (the rest is noise once the pass is known to
    /// have broadly worked).
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
    /// Posted (main thread) after an investments sync pass (LiveSync
    /// exchanges/wallets + price history) — the UI must reload.
    /// Observed in NemorisApp → bumps AppState.dataRefreshToken.
    /// Mirrors the `nemorisSyncDidApplyRemoteChanges` pattern (CloudSyncEngine).
    static let nemorisInvestmentsDidSync = Notification.Name("nemorisInvestmentsDidSync")
}
