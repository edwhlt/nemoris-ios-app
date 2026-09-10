import SwiftUI
import CryptoKit
import Security

// MARK: - Keychain Storage (clés API sensibles)

private enum BinanceKeychain {
    static let apiKeyID  = "binance_api_key"
    static let secretID  = "binance_api_secret"

    static func save(_ value: String, for id: String) {
        let data = Data(value.utf8)
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: id]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData] = data
        attrs[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(id: String) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: id,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAll() {
        [apiKeyID, secretID].forEach { id in
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: id] as CFDictionary)
        }
    }
}

// MARK: - Models

struct FiscalTrade: Identifiable {
    let id: Int64
    let date: Date
    let symbol: String
    let asset: String
    let qtySold: Decimal
    let priceEUR: Decimal    // prix unitaire EUR
    let totalEUR: Decimal    // produit de cession en EUR
    let costBasisEUR: Decimal // coût de revient selon CMP
    let gain: Decimal        // plus/moins-value = totalEUR - costBasisEUR
}

/// Résumé par actif : achats, ventes, CMP, position restante.
/// Permet de vérifier le calcul même si aucune cession fiscale n'a eu lieu cette année.
struct AssetSummary: Identifiable {
    let id: String          // = asset (BTC, ETH…)
    let asset: String
    let totalBoughtQty: Decimal
    let totalBoughtEUR: Decimal
    let totalSoldQty: Decimal
    let totalSoldEUR: Decimal
    let remainingQty: Decimal
    let cmpPerUnit: Decimal     // coût moyen pondéré unitaire final
    let salesCount: Int         // nombre de ventes sur toute la période
}

struct FiscalReport {
    let year: Int
    let trades: [FiscalTrade]
    let scannedSymbols: [String]
    let assetSummaries: [AssetSummary]

    var totalGains: Decimal { trades.filter { $0.gain > 0 }.map(\.gain).reduce(0, +) }
    var totalLosses: Decimal { trades.filter { $0.gain < 0 }.map(\.gain).reduce(0, +) }
    var netGain: Decimal { trades.map(\.gain).reduce(0, +) }
    // Flat Tax PFU = 12,8% IR + 17,2% PS = 30%
    var estimatedTaxPFU: Decimal { max(0, netGain) * Decimal(string: "0.30")! }
}

// MARK: - Binance API

private struct BinanceAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Un enregistrement de la fonctionnalité Convert/Quick Sell de Binance.
/// Ces conversions NE figurent PAS dans /api/v3/myTrades — elles nécessitent
/// l'endpoint /sapi/v1/convert/tradeFlow.
private struct ConvertRecord: Decodable {
    let orderId: String
    let orderStatus: String
    let fromAsset: String
    let fromAmount: String
    let toAsset: String
    let toAmount: String
    let createTime: Int64
}
private struct ConvertTradeFlow: Decodable { let list: [ConvertRecord] }

// Decodage des klines Binance : tableaux hétérogènes [Int64 | String | Double]
private enum KlineValue: Decodable {
    case int(Int64), double(Double), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int64.self)  { self = .int(v);    return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        self = .string((try? c.decode(String.self)) ?? "")
    }
}

private struct RawTrade: Decodable {
    let id: Int64
    let symbol: String
    let price: String
    let qty: String
    let quoteQty: String
    let commission: String
    let commissionAsset: String
    let time: Int64
    let isBuyer: Bool
}

private struct AccountBalance: Decodable {
    let asset: String
    let free: String
    let locked: String
    var total: Decimal { (Decimal(string: free) ?? 0) + (Decimal(string: locked) ?? 0) }
}
private struct AccountResponse: Decodable { let balances: [AccountBalance] }
private struct BinanceErrResponse: Decodable { let code: Int; let msg: String }

private struct BinanceAPI {
    let apiKey: String
    let apiSecret: String
    private let base = "https://api.binance.com"
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func sign(_ query: String) -> String {
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: key)
            .map { String(format: "%02hhx", $0) }.joined()
    }

    /// Requête GET signée avec X-MBX-APIKEY
    private func signedGet<T: Decodable>(path: String, params: String) async throws -> T {
        let query = "\(params)&timestamp=\(now)"
        let sig   = sign(query)
        guard let url = URL(string: "\(base)\(path)?\(query)&signature=\(sig)") else {
            throw BinanceAPIError(message: "URL invalide")
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (try? JSONDecoder().decode(BinanceErrResponse.self, from: data))?.msg ?? "HTTP \(http.statusCode)"
            throw BinanceAPIError(message: msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Requête GET publique (sans auth)
    private func publicGet<T: Decodable>(path: String, params: String) async throws -> T {
        guard let url = URL(string: "\(base)\(path)?\(params)") else {
            throw BinanceAPIError(message: "URL invalide")
        }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Endpoints

    /// Retourne les assets avec solde non nul (hors monnaies fiat stables)
    func fetchAssets() async throws -> [String] {
        let resp: AccountResponse = try await signedGet(path: "/api/v3/account", params: "")
        let stable: Set<String> = ["EUR", "USDT", "BUSD", "USDC", "TUSD", "DAI", "PAX", "FDUSD"]
        return resp.balances
            .filter { $0.total > 0 && !stable.contains($0.asset) }
            .map(\.asset)
    }

    /// Retourne tous les trades pour un symbole depuis startTime jusqu'à endTime.
    /// Gère la pagination automatiquement.
    ///
    /// Note Binance : startTime+endTime simultanément est limité à 24h.
    /// On utilise donc startTime seul pour la première page, puis fromId pour paginer,
    /// et on s'arrête quand le dernier trade dépasse endTime.
    func fetchAllTrades(symbol: String, startTime: Int64, endTime: Int64) async throws -> [RawTrade] {
        var all: [RawTrade] = []
        var lastId: Int64? = nil

        while true {
            var params = "symbol=\(symbol)&limit=1000"
            if let id = lastId {
                // Pages suivantes : pagination par ID, sans contrainte de temps
                params += "&fromId=\(id + 1)"
            } else {
                // Première page : on démarre depuis startTime (sans endTime pour éviter la limite 24h)
                params += "&startTime=\(startTime)"
            }

            let batch: [RawTrade] = try await signedGet(path: "/api/v3/myTrades", params: params)
            guard !batch.isEmpty else { break }

            // Filtre les trades dans la fenêtre souhaitée et arrête si on a dépassé endTime
            let inRange = batch.filter { $0.time <= endTime }
            all.append(contentsOf: inRange)

            if inRange.count < batch.count { break } // au moins un trade était après endTime
            guard batch.count == 1000 else { break }  // dernière page

            lastId = batch.last!.id
            try await Task.sleep(nanoseconds: 80_000_000) // 80ms pour respecter le rate limit
        }
        return all
    }

    /// Historique des conversions (bouton "Convertir" / Quick Sell de Binance).
    /// Binance limite chaque requête à 30 jours — on itère mois par mois.
    /// Disponible depuis ~2021 ; requiert la permission "Lecture des données de trading".
    func fetchConvertHistory(startTime: Int64, endTime: Int64) async throws -> [ConvertRecord] {
        var all: [ConvertRecord] = []
        let thirtyDays: Int64 = 30 * 24 * 60 * 60 * 1000
        var t = startTime

        while t < endTime {
            let tEnd = min(t + thirtyDays, endTime)
            let params = "startTime=\(t)&endTime=\(tEnd)&limit=1000"
            // L'endpoint peut ne pas exister ou retourner une erreur si aucune donnée → on ignore
            if let result = try? await signedGet(path: "/sapi/v1/convert/tradeFlow", params: params) as ConvertTradeFlow {
                all.append(contentsOf: result.list.filter { $0.orderStatus == "SUCCESS" })
            }
            t = tEnd + 1
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        return all
    }

    /// Taux de clôture EUR/USDT sous forme de klines mensuelles pour une année.
    /// Retourne un tableau [(timestamp_ms, rate)] trié chronologiquement.
    func fetchMonthlyEURUSDT(year: Int) async throws -> [(Int64, Decimal)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end   = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let params = "symbol=EURUSDT&interval=1M&startTime=\(Int64(start.timeIntervalSince1970 * 1000))&endTime=\(Int64(end.timeIntervalSince1970 * 1000))&limit=12"

        let klines: [[KlineValue]] = try await publicGet(path: "/api/v3/klines", params: params)
        return klines.compactMap { k -> (Int64, Decimal)? in
            guard k.count > 4,
                  case .int(let t) = k[0],
                  case .string(let close) = k[4],
                  let rate = Decimal(string: close) else { return nil }
            return (t, rate)
        }
    }
}

// MARK: - Convert → RawTrade adapter

/// Traduit un ConvertRecord en RawTrade pour le passer au TaxCalculator.
/// Seules les conversions impliquant EUR ou un stablecoin d'un côté sont traitées
/// (crypto→EUR, EUR→crypto, crypto→USDT, USDT→crypto).
/// Les conversions cross-crypto (BTC→ETH) sont ignorées pour l'instant.
private func convertToRawTrade(_ r: ConvertRecord) -> RawTrade? {
    let stable: Set<String> = ["EUR", "USDT", "BUSD", "USDC", "TUSD", "DAI", "PAX", "FDUSD"]

    guard let fromAmt = Decimal(string: r.fromAmount),
          let toAmt   = Decimal(string: r.toAmount),
          fromAmt > 0, toAmt > 0 else { return nil }

    let fromIsStable = stable.contains(r.fromAsset)
    let toIsStable   = stable.contains(r.toAsset)

    let symbol: String
    let isBuyer: Bool
    let qty: String       // quantité crypto
    let quoteQty: String  // montant fiat/stable
    let price: String

    if toIsStable && !fromIsStable {
        // Vente crypto → fiat/stable  (ex: BTC → EUR ou ETH → USDT)
        symbol   = "\(r.fromAsset)\(r.toAsset)"
        isBuyer  = false
        qty      = r.fromAmount
        quoteQty = r.toAmount
        price    = "\(toAmt / fromAmt)"
    } else if fromIsStable && !toIsStable {
        // Achat crypto avec fiat/stable  (ex: EUR → BTC)
        symbol   = "\(r.toAsset)\(r.fromAsset)"
        isBuyer  = true
        qty      = r.toAmount
        quoteQty = r.fromAmount
        price    = "\(fromAmt / toAmt)"
    } else {
        return nil  // cross-crypto ou stable→stable : ignoré
    }

    return RawTrade(
        id: r.createTime,
        symbol: symbol,
        price: price,
        qty: qty,
        quoteQty: quoteQty,
        commission: "0",
        commissionAsset: r.toAsset,
        time: r.createTime,
        isBuyer: isBuyer
    )
}

// MARK: - Tax Calculator (Coût Moyen Pondéré — méthode CMP)

private enum TaxCalculator {

    // Assets cotés directement en EUR, sinon USDT (converti)
    static let stableQuotes: Set<String> = ["USDT", "BUSD", "USDC", "TUSD", "DAI", "PAX", "FDUSD"]

    /// Extrait (baseAsset, quoteAsset) d'un symbole Binance.
    static func parseSymbol(_ symbol: String) -> (base: String, quote: String)? {
        // Essaie d'abord les quotes les plus longues pour éviter les collisions
        let quotes = ["USDT", "BUSD", "USDC", "TUSD", "FDUSD", "DAI", "PAX", "EUR", "BTC", "ETH", "BNB"]
        for q in quotes {
            if symbol.hasSuffix(q), symbol.count > q.count {
                return (String(symbol.dropLast(q.count)), q)
            }
        }
        return nil
    }

    /// Calcule les plus/moins-values selon la méthode CMP.
    ///
    /// - Parameters:
    ///   - trades: Tous les trades historiques (y compris avant l'année fiscale, pour la base de coût).
    ///   - eurRates: Tableau (timestamp_ms, USDT→EUR rate) pour convertir les paires USDT.
    ///   - year: Année fiscale (seules les cessions de cette année sont dans `fiscalTrades`).
    /// - Returns: Tuple (cessions fiscales de l'année, résumé par actif sur toute la période).
    static func calculate(
        trades: [RawTrade],
        eurRates: [(Int64, Decimal)],
        year: Int
    ) -> (fiscalTrades: [FiscalTrade], summaries: [AssetSummary]) {

        // Fonction de conversion USDT→EUR par interpolation
        func usdtToEUR(at time: Int64) -> Decimal {
            guard !eurRates.isEmpty else { return Decimal(string: "0.92")! }
            let closest = eurRates.min { abs($0.0 - time) < abs($1.0 - time) }!
            return closest.1
        }

        // Regroupe les trades par asset de base
        var byAsset: [String: [RawTrade]] = [:]
        for trade in trades {
            guard let (base, quote) = parseSymbol(trade.symbol) else { continue }
            // Ignore les paires cross-crypto (BTC/ETH/BNB) — trop complexes sans prix EUR direct
            guard quote == "EUR" || stableQuotes.contains(quote) else { continue }
            byAsset[base, default: []].append(trade)
        }

        var results:   [FiscalTrade]   = []
        var summaries: [AssetSummary]  = []
        let cal = Calendar.current

        for (asset, assetTrades) in byAsset {
            let sorted = assetTrades.sorted { $0.time < $1.time }

            // État CMP pour cet asset
            var holdingQty:     Decimal = 0
            var holdingCostEUR: Decimal = 0

            // Compteurs pour AssetSummary
            var totalBoughtQty: Decimal = 0
            var totalBoughtEUR: Decimal = 0
            var totalSoldQty:   Decimal = 0
            var totalSoldEUR:   Decimal = 0
            var salesCount:     Int     = 0

            for raw in sorted {
                guard let (_, quote) = parseSymbol(raw.symbol) else { continue }

                let qty      = Decimal(string: raw.qty)      ?? 0
                let quoteQty = Decimal(string: raw.quoteQty) ?? 0
                let price    = Decimal(string: raw.price)    ?? 0
                let date     = Date(timeIntervalSince1970: TimeInterval(raw.time) / 1000)

                // Convertit en EUR
                let eurRate: Decimal  = stableQuotes.contains(quote) ? usdtToEUR(at: raw.time) : 1
                let totalEUR: Decimal = quote == "EUR" ? quoteQty : quoteQty / eurRate
                let priceEUR: Decimal = quote == "EUR" ? price    : price    / eurRate

                if raw.isBuyer {
                    // ── Achat : mise à jour du CMP ──
                    holdingQty     += qty
                    holdingCostEUR += totalEUR
                    totalBoughtQty += qty
                    totalBoughtEUR += totalEUR
                } else {
                    // ── Vente : calcul de la plus/moins-value ──
                    let avgCost   = holdingQty > 0 ? holdingCostEUR / holdingQty : 0
                    let costBasis = avgCost * qty
                    let gain      = totalEUR - costBasis

                    // Mise à jour du stock restant
                    holdingQty     = max(0, holdingQty - qty)
                    holdingCostEUR = max(0, avgCost * holdingQty)

                    totalSoldQty += qty
                    totalSoldEUR += totalEUR
                    salesCount   += 1

                    // N'inclure que les cessions de l'année fiscale sélectionnée
                    if cal.component(.year, from: date) == year {
                        results.append(FiscalTrade(
                            id: raw.id,
                            date: date,
                            symbol: raw.symbol,
                            asset: asset,
                            qtySold: qty,
                            priceEUR: priceEUR,
                            totalEUR: totalEUR,
                            costBasisEUR: costBasis,
                            gain: gain
                        ))
                    }
                }
            }

            let cmpPerUnit = holdingQty > 0 ? holdingCostEUR / holdingQty : 0
            summaries.append(AssetSummary(
                id: asset,
                asset: asset,
                totalBoughtQty: totalBoughtQty,
                totalBoughtEUR: totalBoughtEUR,
                totalSoldQty: totalSoldQty,
                totalSoldEUR: totalSoldEUR,
                remainingQty: holdingQty,
                cmpPerUnit: cmpPerUnit,
                salesCount: salesCount
            ))
        }

        return (results.sorted { $0.date < $1.date }, summaries.sorted { $0.asset < $1.asset })
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class BinanceTaxViewModel {
    var apiKey:    String = ""
    var apiSecret: String = ""
    var year: Int = Calendar.current.component(.year, from: Date())

    var isLoading  = false
    var progress   = ""
    var error: String?
    var report: FiscalReport?
    var diagnosticLog: [String] = []
    /// Actifs supplémentaires à scanner même si leur solde est nul (séparés par virgule).
    /// Utile quand tous les cryptos ont été vendus (solde = 0 = introuvable via fetchAssets).
    var additionalAssetsInput: String = ""

    var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var credentialsSaved: Bool {
        BinanceKeychain.load(id: BinanceKeychain.apiKeyID) != nil
    }

    init() {
        apiKey    = BinanceKeychain.load(id: BinanceKeychain.apiKeyID)  ?? ""
        apiSecret = BinanceKeychain.load(id: BinanceKeychain.secretID)  ?? ""
    }

    func saveCredentials() {
        BinanceKeychain.save(apiKey,    for: BinanceKeychain.apiKeyID)
        BinanceKeychain.save(apiSecret, for: BinanceKeychain.secretID)
    }

    func deleteCredentials() {
        BinanceKeychain.deleteAll()
        apiKey = ""; apiSecret = ""
    }

    // MARK: - Main calculation

    func testConnection() async {
        guard hasCredentials else { return }
        isLoading = true
        error = nil
        diagnosticLog = []
        defer { isLoading = false }

        let api = BinanceAPI(apiKey: apiKey, apiSecret: apiSecret)
        progress = "Test de connexion…"
        do {
            let assets = try await api.fetchAssets()
            if assets.isEmpty {
                diagnosticLog.append("✅ Connexion OK — aucun actif non-stable trouvé (compte peut-être vide ou 100% stables)")
            } else {
                diagnosticLog.append("✅ Connexion OK — \(assets.count) actif(s) trouvé(s) : \(assets.joined(separator: ", "))")
            }
            progress = "Test réussi"
        } catch {
            diagnosticLog.append("❌ Erreur de connexion : \(error.localizedDescription)")
            self.error = "Connexion échouée : \(error.localizedDescription)"
            progress = ""
        }
    }

    func calculate() async {
        guard hasCredentials else { return }
        isLoading = true
        error = nil
        report = nil
        diagnosticLog = []
        defer { isLoading = false }

        let api = BinanceAPI(apiKey: apiKey, apiSecret: apiSecret)

        // Bornes temporelles :
        // • Pour la base de coût (CMP), on remonte au 1er janvier 2017 (lancement Binance)
        // • On arrête au 31/12 de l'année sélectionnée
        // • Convert existe depuis ~2021 — on démarre le scan convert en 2021
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start2017    = cal.date(from: DateComponents(year: 2017, month: 1, day: 1))!
        let start2021    = cal.date(from: DateComponents(year: 2021, month: 1, day: 1))!
        let endOfYear    = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let startMs      = Int64(start2017.timeIntervalSince1970 * 1000)
        let convertStart = Int64(start2021.timeIntervalSince1970 * 1000)
        let endMs        = Int64(endOfYear.timeIntervalSince1970  * 1000)

        // 1. Récupère les assets avec solde non nul (peut être vide si tout vendu)
            progress = "Récupération des actifs du compte…"
            let spotAssets = (try? await api.fetchAssets()) ?? []
            if spotAssets.isEmpty {
                diagnosticLog.append("ℹ️ Aucun actif spot avec solde > 0 (tout vendu ou 100% stables)")
            } else {
                diagnosticLog.append("✅ \(spotAssets.count) actif(s) spot : \(spotAssets.joined(separator: ", "))")
            }

            // 2. Taux EUR/USDT mensuels
            progress = "Récupération des taux EUR/USDT…"
            let eurRates = (try? await api.fetchMonthlyEURUSDT(year: year)) ?? []
            diagnosticLog.append(eurRates.isEmpty
                ? "⚠️ Taux EUR/USDT non disponibles, fallback 0.92 utilisé"
                : "✅ \(eurRates.count) taux EUR/USDT chargés")

            // 3. Historique Convert (bouton "Convertir" / Quick Sell — NE figure PAS dans myTrades)
            progress = "Récupération de l'historique Convert (vente rapide)…"
            let convertRecords = (try? await api.fetchConvertHistory(startTime: convertStart, endTime: endMs)) ?? []
            let convertTrades  = convertRecords.compactMap { convertToRawTrade($0) }

            // Assets découverts via Convert (utiles si solde spot = 0)
            let convertAssets = Set(convertTrades.compactMap { trade -> String? in
                TaxCalculator.parseSymbol(trade.symbol)?.base
            })

            if convertRecords.isEmpty {
                diagnosticLog.append("ℹ️ Aucune conversion trouvée via Convert/Quick Sell depuis 2021")
            } else {
                diagnosticLog.append("✅ \(convertRecords.count) conversion(s) Convert : \(convertAssets.sorted().joined(separator: ", "))")
            }

            // 4. Actifs saisis manuellement (utile si solde = 0 et pas de Convert)
            let manualAssets = additionalAssetsInput
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty }
            if !manualAssets.isEmpty {
                diagnosticLog.append("➕ Actifs manuels : \(manualAssets.joined(separator: ", "))")
            }

            // 5. Liste complète des assets à scanner via spot
            let assetsToScan = Array(Set(spotAssets + Array(convertAssets) + manualAssets))

            guard !assetsToScan.isEmpty else {
                error = "Aucun actif à analyser. Ajoutez des actifs manuellement (ex: BTC,ETH) si vous avez tout vendu."
                diagnosticLog.append("❌ Aucun actif détecté via spot, Convert ou saisie manuelle.")
                return
            }

            // 6. Récupère les trades spot pour tous les assets détectés
            let symbols = assetsToScan.sorted().flatMap { ["\($0)EUR", "\($0)USDT"] }
            diagnosticLog.append("🔍 \(symbols.count) symboles spot à interroger : \(symbols.joined(separator: ", "))")

            var spotTrades:     [RawTrade] = []
            var scannedSymbols: [String]   = []

            for symbol in symbols {
                progress = "Analyse de \(symbol)…"
                do {
                    let trades = try await api.fetchAllTrades(
                        symbol: symbol, startTime: startMs, endTime: endMs
                    )
                    if !trades.isEmpty {
                        spotTrades.append(contentsOf: trades)
                        scannedSymbols.append(symbol)
                        diagnosticLog.append("✅ \(symbol) : \(trades.count) trade(s)")
                    } else {
                        diagnosticLog.append("— \(symbol) : aucun trade (symbole valide)")
                    }
                } catch let e as BinanceAPIError {
                    if e.message.contains("-1121") || e.message.contains("Invalid symbol") { continue }
                    diagnosticLog.append("❌ \(symbol) : \(e.message)")
                } catch {
                    diagnosticLog.append("❌ \(symbol) : \(error.localizedDescription)")
                }
            }

            // 7. Fusion spot + Convert
            let allTrades = spotTrades + convertTrades

            if !convertTrades.isEmpty {
                scannedSymbols.append(contentsOf: convertAssets.sorted().flatMap { ["\($0)EUR", "\($0)USDT"] }
                    .filter { !scannedSymbols.contains($0) })
                diagnosticLog.append("📥 \(convertTrades.count) trade(s) Convert ajouté(s) au calcul")
            }

            guard !allTrades.isEmpty else {
                error = "Aucune transaction trouvée. Consultez le journal de diagnostic."
                diagnosticLog.append("⚠️ Causes possibles :")
                diagnosticLog.append("  • Clé API sans permission 'Lecture des données de trading'")
                diagnosticLog.append("  • Actifs tradés hors spot/Convert (P2P, earn, staking…)")
                diagnosticLog.append("  • Saisissez manuellement les actifs que vous avez échangés")
                return
            }

            diagnosticLog.append("📊 Total : \(allTrades.count) transaction(s) (\(spotTrades.count) spot + \(convertTrades.count) Convert)")

            // 8. Calcul fiscal (CMP)
            progress = "Calcul des plus/moins-values (CMP)…"
            let (fiscalTrades, summaries) = TaxCalculator.calculate(
                trades: allTrades, eurRates: eurRates, year: year
            )

            report = FiscalReport(
                year: year,
                trades: fiscalTrades,
                scannedSymbols: scannedSymbols,
                assetSummaries: summaries
            )
            progress = "Terminé"
    }
}

// MARK: - View

struct BinanceTaxView: View {
    @State private var vm = BinanceTaxViewModel()
    @State private var editingCredentials = false
    @State private var showDiagnostic = false

    var body: some View {
        Form {
            apiSection
            Section("Année fiscale") {
                Stepper("Année \(vm.year.yearLabel)", value: $vm.year, in: 2017...Calendar.current.component(.year, from: Date()))
            }
            calculationSection
            additionalAssetsSection
            if let report = vm.report { reportSection(report) }
            disclaimerSection
        }
        .nemorisFormStyle()
        .localizedNavigationTitle("Fiscal Binance")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Sections

    private var apiSection: some View {
        Section {
            if vm.credentialsSaved && !editingCredentials {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(AppTheme.Colors.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clés API enregistrées").fontWeight(.medium)
                        Text("Stockées dans le Keychain sécurisé")
                            .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, 2)
                Button("Modifier les clés", role: .destructive) {
                    vm.deleteCredentials()
                    editingCredentials = true
                }
            } else {
                TextField("API Key", text: $vm.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                SecureField("API Secret", text: $vm.apiSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button("Enregistrer dans le Keychain") {
                    vm.saveCredentials()
                    editingCredentials = false
                }
                .disabled(!vm.hasCredentials)
            }
        } header: {
            Text("Clés API Binance")
        } footer: {
            if !vm.credentialsSaved || editingCredentials {
                Text("Créez une clé **en lecture seule** dans Binance › Profil › Gestion des API. Les clés sont chiffrées dans le Keychain de votre iPhone et ne quittent jamais l'appareil.")
            }
        }
    }

    @ViewBuilder
    private var calculationSection: some View {
        Section {
            Button {
                Task { await vm.calculate() }
            } label: {
                if vm.isLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(vm.progress)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .font(.subheadline)
                    }
                } else {
                    Label("Calculer le rapport \(vm.year.yearLabel)", systemImage: "doc.text.magnifyingglass")
                        .fontWeight(.medium)
                }
            }
            .disabled(!vm.hasCredentials || vm.isLoading)

            Button {
                Task { await vm.testConnection() }
            } label: {
                Label("Tester la connexion", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(!vm.hasCredentials || vm.isLoading)

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.Colors.danger)
                    .font(.caption)
            }
        }

        if !vm.diagnosticLog.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showDiagnostic) {
                    ForEach(vm.diagnosticLog, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } label: {
                    Label("Journal de diagnostic (\(vm.diagnosticLog.count) entrées)", systemImage: "list.bullet.clipboard")
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private func reportSection(_ report: FiscalReport) -> some View {
        // Résumé fiscal
        Section {
            summaryRow("Plus-values", value: report.totalGains, positive: true)
            summaryRow("Moins-values", value: report.totalLosses, positive: false)
            Divider()
            LabeledContent("Net imposable") {
                Text(report.netGain, format: .currency(code: "EUR"))
                    .fontWeight(.bold)
                    .foregroundStyle(report.netGain >= 0 ? AnyShapeStyle(AppTheme.Colors.textPrimary) : AnyShapeStyle(AppTheme.Colors.success))
            }
            LabeledContent("Impôt estimé (PFU 30%)") {
                Text(report.estimatedTaxPFU, format: .currency(code: "EUR"))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.warning)
            }
        } header: {
            Text("Résumé \(report.year.yearLabel)")
        } footer: {
            Text("Symboles analysés : \(report.scannedSymbols.joined(separator: ", "))")
                .font(.caption2)
        }

        // Détail par actif (achats, ventes, CMP — visible même si 0 cession cette année)
        if !report.assetSummaries.isEmpty {
            Section {
                ForEach(report.assetSummaries) { s in
                    assetSummaryRow(s)
                }
            } header: {
                Text("Détail par actif (depuis 2017)")
            } footer: {
                Text("Le CMP (coût moyen pondéré) est calculé sur tout l'historique pour garantir l'exactitude fiscale.")
                    .font(.caption2)
            }
        }

        // Liste des cessions de l'année sélectionnée
        if report.trades.isEmpty {
            Section {
                if report.assetSummaries.allSatisfy({ $0.salesCount == 0 }) {
                    Label("Aucune vente détectée. Vous n'avez fait qu'acheter sur cette période.", systemImage: "arrow.down.circle")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.subheadline)
                } else {
                    Label("Aucune cession en \(report.year.yearLabel). Les ventes ont eu lieu sur d'autres années.", systemImage: "calendar.badge.minus")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.subheadline)
                }
            } header: {
                Text("Cessions \(report.year.yearLabel)")
            }
        } else {
            Section {
                ForEach(report.trades) { trade in
                    tradeRow(trade)
                }
            } header: {
                Text("Cessions \(report.year.yearLabel) (\(report.trades.count))")
            }

            Section {
                ShareLink(
                    item: generateCSV(report),
                    preview: SharePreview("rapport_fiscal_\(report.year.yearLabel).csv",
                                         image: Image(systemName: "doc.text"))
                ) {
                    Label("Exporter le rapport CSV", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Le CSV est compatible avec la déclaration cerfa 2086.")
            }
        }
    }

    private var additionalAssetsSection: some View {
        Section {
            TextField("BTC, ETH, SOL…", text: $vm.additionalAssetsInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        } header: {
            Text("Actifs supplémentaires")
        } footer: {
            Text("Si vous avez **tout vendu** (solde = 0), Binance ne retourne plus vos actifs. Listez ici les cryptos que vous avez tradés (séparés par une virgule) pour forcer l'analyse des ordres spot passés.")
        }
    }

    private var disclaimerSection: some View {
        Section {
            Label {
                Text("Ce rapport utilise la méthode du **Coût Moyen Pondéré (CMP)**. Il est fourni à titre indicatif et ne constitue pas un conseil fiscal. Consultez un expert-comptable pour votre déclaration officielle (formulaire 2086, Article 150 VH bis CGI).")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Row builders

    private func summaryRow(_ label: String, value: Decimal, positive: Bool) -> some View {
        LabeledContent(label) {
            Text(value, format: .currency(code: "EUR"))
                .foregroundStyle(value == 0 ? AppTheme.Colors.textSecondary : (positive ? AppTheme.Colors.success : AppTheme.Colors.danger))
        }
    }

    private func assetSummaryRow(_ s: AssetSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(s.asset).fontWeight(.semibold)
                Spacer()
                if s.salesCount > 0 {
                    Text("\(s.salesCount) vente(s)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.Colors.warning.opacity(0.12), in: Capsule())
                } else {
                    Text("Aucune vente")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }

            // Achats
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(AppTheme.Colors.accent)
                Text("Acheté \(s.totalBoughtQty, format: .number.precision(.fractionLength(4...6))) \(s.asset)")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text(s.totalBoughtEUR, format: .currency(code: "EUR"))
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }

            // Ventes (si existantes)
            if s.totalSoldQty > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill").font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                    Text("Vendu \(s.totalSoldQty, format: .number.precision(.fractionLength(4...6))) \(s.asset)")
                        .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    Text(s.totalSoldEUR, format: .currency(code: "EUR"))
                        .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            // Position restante + CMP
            if s.remainingQty > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill").font(.caption2).foregroundStyle(AppTheme.Colors.success)
                    Text("Position : \(s.remainingQty, format: .number.precision(.fractionLength(4...6))) \(s.asset)")
                        .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    Text("CMP \(s.cmpPerUnit, format: .currency(code: "EUR"))")
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func tradeRow(_ trade: FiscalTrade) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trade.asset)
                    .fontWeight(.semibold)
                Spacer()
                Text(trade.gain, format: .currency(code: "EUR"))
                    .fontWeight(.medium)
                    .foregroundStyle(trade.gain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            }
            HStack {
                Text(trade.date, format: .dateTime.day().month().year())
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text("Cession \(trade.totalEUR, format: .currency(code: "EUR")) · Base \(trade.costBasisEUR, format: .currency(code: "EUR"))")
                    .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - CSV export

    private func generateCSV(_ report: FiscalReport) -> String {
        var lines = ["Date,Actif,Symbole,Qté vendue,Prix unitaire EUR,Total cession EUR,Coût de revient EUR,Plus-value EUR"]
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]

        for t in report.trades {
            lines.append([
                df.string(from: t.date),
                t.asset,
                t.symbol,
                "\(t.qtySold)",
                "\(t.priceEUR)",
                "\(t.totalEUR)",
                "\(t.costBasisEUR)",
                "\(t.gain)"
            ].joined(separator: ","))
        }

        lines += [
            "",
            "RÉSUMÉ",
            "Année,\(report.year)",
            "Plus-values brutes,\(report.totalGains)",
            "Moins-values brutes,\(report.totalLosses)",
            "Net imposable,\(report.netGain)",
            "Impôt estimé PFU 30%,\(report.estimatedTaxPFU)",
            "",
            "Symboles analysés,\(report.scannedSymbols.joined(separator: " | "))",
            "Méthode de calcul,Coût Moyen Pondéré (CMP)",
        ]

        return lines.joined(separator: "\n")
    }
}
