import Foundation
import Observation

@Observable
@MainActor
final class InvestmentsViewModel {
    var accounts: [InvestmentAccount] = []
    var selectedAccountId: Int?
    var positions: [InvestmentPosition] = []
    var csvHeaders: [String] = []
    var csvRows: [[String]] = []
    var csvErrors: [String] = []
    var csvWarnings: [String] = []
    var importFailures: [InvestmentImportFailure] = []
    var previewRows: [InvestmentCSVPreviewRow] = []
    var isEnrichingPreview = false
    var marketHistory: [InvestmentPricePoint] = []
    var isSyncingMarketData = false
    var marketStatusMessage: String?

    // AXE J — état pour le nouveau dashboard graphique
    /// Plage temporelle sélectionnée pour le chart d'évolution.
    var selectedTimeRange: InvestmentTimeRange = .threeMonth
    /// Évolution calculée du portefeuille global sur la plage sélectionnée.
    var portfolioEvolution: [PortfolioEvolutionPoint] = []
    /// Toggle UI : affiche allocation par type ou par compte.
    var allocationGroupByAccount: Bool = false
    /// Cache de TOUTES les positions de TOUS les comptes (chargé dans `load()`).
    /// Sert de source unique pour tous les calculs agrégés (portfolio total,
    /// allocations, dashboard stats) à la place de `account.currentValue` qui
    /// n'est jamais resynchronisé quand les positions sont updated.
    var allPositions: [InvestmentPosition] = []

    /// Chantier B — sparkline 1 mois par compte (id → points), affichée dans la
    /// liste des comptes du dashboard (style Apple Stocks). Calculée en fin de
    /// `load()` depuis le PriceHistoryCache (RAM) — coût négligeable.
    var accountSparklines: [Int: [PortfolioEvolutionPoint]] = [:]

    private let repository = InvestmentRepository()
    private let marketDataService = InvestmentMarketDataService()

    var selectedAccount: InvestmentAccount? {
        guard let selectedAccountId else { return nil }
        return accounts.first(where: { $0.id == selectedAccountId })
    }

    var dashboard: InvestmentDashboardStats {
        // AXE J — tout dérivé de allPositions (vrai état) au lieu de
        // account.currentValue (cache jamais resynchronisé qui restait à 0).
        let totalValuation = allPositions.reduce(0) { $0 + $1.currentValue }
        let totalInvested = allPositions.reduce(0) { $0 + $1.investedAmount }

        let byAsset = Dictionary(grouping: allPositions) { $0.assetType }
            .map { key, values in
                InvestmentAllocationItem(name: key, value: values.reduce(0) { $0 + $1.currentValue })
            }
            .sorted { $0.value > $1.value }

        // Pour byAccount : somme des positions de chaque compte (pas account.currentValue)
        let positionsByAccount = Dictionary(grouping: allPositions) { $0.accountId }
        let byAccount = accounts
            .map { account in
                let val = positionsByAccount[account.id]?.reduce(0) { $0 + $1.currentValue } ?? 0
                return InvestmentAllocationItem(name: account.name, value: val)
            }
            .sorted { $0.value > $1.value }

        let evolution = accounts
            .map { account in
                let val = positionsByAccount[account.id]?.reduce(0) { $0 + $1.currentValue } ?? 0
                return InvestmentAllocationItem(name: account.openedAt.formatted(date: .abbreviated, time: .omitted), value: val)
            }
            .sorted { $0.name < $1.name }

        return InvestmentDashboardStats(
            totalValuation: totalValuation,
            totalInvested: totalInvested,
            byAssetType: byAsset,
            byAccount: byAccount,
            evolution: evolution
        )
    }

    func load() {
        accounts = repository.fetchAccounts()
        if selectedAccountId == nil {
            selectedAccountId = accounts.first?.id
        }
        loadPositions()
        // AXE J : charge le cache global de toutes les positions de tous les comptes
        // (source unique pour dashboard.totalValuation, allocations, hero, etc.)
        allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }
        // AXE J : refresh l'évolution pour le dashboard graphique
        recomputePortfolioEvolution()
        // Chantier B : sparkline 1 mois par compte pour la liste du dashboard.
        var sparklines: [Int: [PortfolioEvolutionPoint]] = [:]
        for account in accounts {
            let points = computeAccountEvolution(accountId: account.id, range: .oneMonth)
            if points.count >= 2 { sparklines[account.id] = points }
        }
        accountSparklines = sparklines
    }

    func loadPositions() {
        guard let selectedAccountId else {
            positions = []
            return
        }
        positions = repository.fetchPositions(accountId: selectedAccountId)
    }

    func saveAccount(_ account: InvestmentAccount, isNew: Bool) {
        if isNew {
            _ = repository.addAccount(
                name: account.name,
                broker: account.broker,
                currency: account.currency,
                accountType: account.accountType,
                currentValue: account.currentValue,
                investedAmount: account.investedAmount,
                openedAt: account.openedAt
            )
        } else {
            _ = repository.updateAccount(account)
        }
        load()
    }

    func deleteAccount(id: Int) {
        _ = repository.deleteAccount(id: id)
        if selectedAccountId == id {
            selectedAccountId = nil
        }
        load()
    }

    func savePosition(_ position: InvestmentPosition, isNew: Bool) {
        if isNew {
            _ = repository.addPosition(
                accountId: position.accountId,
                assetType: position.assetType,
                assetName: position.assetName,
                ticker: position.ticker,
                quantity: position.quantity,
                averageBuyPrice: position.averageBuyPrice,
                currentValue: position.currentValue,
                purchaseDate: position.purchaseDate
            )
        } else {
            _ = repository.updatePosition(position)
        }
        loadPositions()
    }

    func deletePosition(id: Int) {
        _ = repository.deletePosition(id: id)
        loadPositions()
    }

    func loadCSV(content: String) {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else {
            csvErrors = ["Fichier CSV vide"]
            return
        }
        let separator = detectSeparator(header)
        csvHeaders = parseCSVLine(header, separator: separator)
        csvRows = lines.dropFirst().map { parseCSVLine($0, separator: separator) }
        csvErrors = []
        csvWarnings = []
        importFailures = []
        previewRows = []
    }

    func buildCSVPreview(mapping: InvestmentCSVMapping, dateStrategy: InvestmentCSVDateStrategy) {
        guard !csvHeaders.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        func parseAmount(_ raw: String) -> Double? {
            var value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            value = value.replacingOccurrences(of: ",", with: ".")
            return Double(value)
        }

        csvErrors = []
        csvWarnings = []
        importFailures = []
        previewRows = []

        for (index, row) in csvRows.enumerated() {
            let lineNo = index + 2
            guard let isinIdx = csvHeaders.firstIndex(of: mapping.isin),
                  let qtyIdx = csvHeaders.firstIndex(of: mapping.quantity),
                  let avgIdx = csvHeaders.firstIndex(of: mapping.averageBuyPrice) else {
                csvErrors.append("Ligne \(lineNo): mapping invalide")
                continue
            }
            let dateIdx = mapping.purchaseDate.isEmpty ? nil : csvHeaders.firstIndex(of: mapping.purchaseDate)

            let requiredMaxIndex = [isinIdx, qtyIdx, avgIdx, dateIdx]
                .compactMap { $0 }
                .max() ?? 0
            guard row.count > requiredMaxIndex else {
                csvErrors.append("Ligne \(lineNo): colonnes manquantes")
                continue
            }

            let isinRaw = row[isinIdx].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !isinRaw.isEmpty else {
                csvErrors.append("Ligne \(lineNo): ISIN obligatoire")
                continue
            }

            guard let qty = parseAmount(row[qtyIdx]), qty > 0,
                  let avg = parseAmount(row[avgIdx]), avg > 0 else {
                csvErrors.append("Ligne \(lineNo): quantité/prix d'achat invalides")
                continue
            }
            let currentValue = qty * avg

            let parsedDate = dateIdx.flatMap { formatter.date(from: row[$0].trimmingCharacters(in: .whitespaces)) }
            let date: Date
            if let parsedDate {
                date = parsedDate
            } else {
                switch dateStrategy {
                case .requireDate:
                    csvErrors.append("Ligne \(lineNo): date invalide ou absente, format attendu yyyy-MM-dd")
                    continue
                case .useToday:
                    date = Date()
                case .useAccountOpeningDate(let openedAt):
                    date = openedAt
                }
            }

            previewRows.append(InvestmentCSVPreviewRow(
                sourceRow: lineNo,
                assetType: InvestmentAssetType.stock.rawValue,
                assetName: "ISIN \(isinRaw)",
                ticker: isinRaw,
                quantity: qty,
                averageBuyPrice: avg,
                currentValue: qty * avg,
                purchaseDate: date
            ))
        }
    }

    func enrichPreviewRowsFromISIN() async {
        guard !previewRows.isEmpty else { return }
        isEnrichingPreview = true
        defer { isEnrichingPreview = false }
        csvWarnings = []

        for idx in previewRows.indices {
            let isin = previewRows[idx].ticker
            guard let metadata = await marketDataService.resolveInstrumentFromISIN(isin) else {
                csvWarnings.append("Ligne \(previewRows[idx].sourceRow): enrichissement ISIN introuvable (\(isin))")
                continue
            }

            let mappedType = mapAssetType(from: metadata.quoteType)
            let tradableSymbol = marketDataService.preferredTradableSymbol(from: metadata)
            previewRows[idx] = InvestmentCSVPreviewRow(
                sourceRow: previewRows[idx].sourceRow,
                assetType: mappedType.rawValue,
                assetName: metadata.name,
                ticker: tradableSymbol.uppercased(),
                quantity: previewRows[idx].quantity,
                averageBuyPrice: previewRows[idx].averageBuyPrice,
                currentValue: previewRows[idx].currentValue,
                purchaseDate: previewRows[idx].purchaseDate
            )
        }
    }

    func importPreviewRows() -> InvestmentImportResult {
        guard let selectedAccountId else {
            return InvestmentImportResult(
                insertedCount: 0,
                failures: [InvestmentImportFailure(sourceRow: 0, identifier: "", quantity: 0, averageBuyPrice: 0, reason: "Aucun compte sélectionné")]
            )
        }
        let result = repository.insertPositionsDetailed(previewRows, accountId: selectedAccountId)
        importFailures = result.failures
        loadPositions()
        return result
    }

    func loadCachedMarketHistory(for identifier: String) {
        marketHistory = repository.fetchPriceHistory(identifier: identifier)
    }

    // MARK: - AXE J — Portfolio evolution (Niveau Global)

    /// Calcule l'évolution du portefeuille total sur la plage sélectionnée.
    /// Pour chaque date couverte par l'historique de prix de l'une des positions,
    /// on compose la valorisation totale = Σ (qty × close(ticker, date)).
    /// Si un ticker n'a pas de prix à cette date, on utilise le prix antérieur le plus récent
    /// (forward-fill) ou à défaut le PRU (averageBuyPrice).
    ///
    /// Note : pour les comptes sans aucun historique synchronisé, on n'a pas d'évolution
    /// réelle — la fonction retourne un tableau vide. L'EvolutionChart affiche un placeholder.
    func recomputePortfolioEvolution() {
        // 1. Récupère TOUTES les positions de TOUS les comptes (pas juste selectedAccountId)
        let allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }
        guard !allPositions.isEmpty else {
            portfolioEvolution = []
            return
        }

        // 2. Historiques par POSITION (pas par ticker) via la résolution robuste
        //    ISIN → ticker → symbole résolu par la dernière sync.
        //
        //    ⚠️ Avant, cette fonction ne cherchait QUE par `position.ticker` : dès
        //    que l'historique était stocké sous l'ISIN ou sous un symbole résolu
        //    (ex. ISIN → EWLD.PA via OpenFIGI), le chart GLOBAL restait vide
        //    ("Aucun historique") alors que les écrans compte/position — qui
        //    utilisaient déjà la résolution complète — affichaient bien la courbe.
        let cutoff = selectedTimeRange.startDate
        var historyByPositionId: [Int: [InvestmentPricePoint]] = [:]
        for position in allPositions {
            let history = resolveHistory(for: position, cutoff: cutoff)
            if !history.isEmpty {
                historyByPositionId[position.id] = history
            }
        }

        guard !historyByPositionId.isEmpty else {
            portfolioEvolution = []
            return
        }

        // 3. Union des dates de tous les historiques (set pour déduplication)
        let allDates = Set(historyByPositionId.values.flatMap { $0.map(\.date) }).sorted()

        // 4. Pour chaque date, somme des valorisations (forward-fill par position)
        var lastKnownPrice: [Int: Double] = [:]
        var points: [PortfolioEvolutionPoint] = []

        for date in allDates {
            var total: Double = 0
            for position in allPositions {
                // Cherche le prix le plus récent ≤ date pour cette position
                if let history = historyByPositionId[position.id],
                   let latestBeforeDate = history.last(where: { $0.date <= date }) {
                    lastKnownPrice[position.id] = latestBeforeDate.close
                }
                // Fallback : dernier prix connu OU PRU si jamais syncé
                let price = lastKnownPrice[position.id] ?? position.averageBuyPrice
                total += position.quantity * price
            }
            points.append(PortfolioEvolutionPoint(date: date, value: total))
        }

        portfolioEvolution = points
    }

    /// Résolution ROBUSTE de l'historique de cours d'une position.
    /// Essaie dans l'ordre : ISIN → ticker → symboles retenus par la dernière
    /// synchro réussie (ex. un ISIN résolu en "PUST.PA" via OpenFIGI est stocké
    /// sous ce symbole). Source unique utilisée par TOUS les niveaux de chart
    /// (global, compte, position) — sinon le parent peut rester vide alors que
    /// l'enfant s'affiche.
    private func resolveHistory(for position: InvestmentPosition, cutoff: Date?) -> [InvestmentPricePoint] {
        func load(_ identifier: String) -> [InvestmentPricePoint] {
            repository.fetchPriceHistory(identifier: identifier)
                .sorted { $0.date < $1.date }
                .filter { point in
                    guard let cutoff else { return true }
                    return point.date >= cutoff
                }
        }

        let candidates = [position.isin, position.ticker].filter { !$0.isEmpty }
        for candidate in candidates {
            let history = load(candidate)
            if !history.isEmpty { return history }
        }
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: candidates),
           trace.status == .success {
            for symbol in trace.symbolsTried {
                let history = load(symbol)
                if !history.isEmpty { return history }
            }
        }
        return []
    }

    /// Allocation par type d'actif (toutes positions confondues) — pour le donut chart.
    /// AXE J : utilise le cache `allPositions` (au lieu de fetcher la DB à chaque render).
    var allocationByAssetType: [AllocationSlice] {
        Dictionary(grouping: allPositions, by: { $0.assetType })
            .map { key, positions in
                AllocationSlice(name: assetTypeDisplayName(key),
                                value: positions.reduce(0) { $0 + $1.currentValue })
            }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    /// Allocation par compte — pour le donut chart en mode "par compte".
    /// AXE J : utilise le cache `allPositions` au lieu de `account.currentValue`
    /// (qui restait à 0 et faisait disparaître la section).
    var allocationByAccount: [AllocationSlice] {
        let positionsByAccount = Dictionary(grouping: allPositions) { $0.accountId }
        return accounts
            .map { account in
                let value = positionsByAccount[account.id]?.reduce(0) { $0 + $1.currentValue } ?? 0
                return AllocationSlice(name: account.name, value: value)
            }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    /// Renvoie la valeur du portefeuille au début de la plage temporelle (pour calculer
    /// la variation affichée dans le hero card). Si pas d'historique, renvoie nil.
    var portfolioStartValue: Double? {
        portfolioEvolution.first?.value
    }

    /// Valorisation totale courante = somme des `currentValue` de toutes les positions
    /// de tous les comptes. AXE J : fixé pour utiliser le cache `allPositions` (la
    /// version précédente utilisait `account.currentValue` qui n'est jamais synchronisé
    /// et restait à 0 → hero affichait toujours 0,00 € même avec des positions valorisées).
    var portfolioCurrentValue: Double {
        allPositions.reduce(0) { $0 + $1.currentValue }
    }

    /// Total cash (trésorerie) sur tous les comptes. À ajouter au `portfolioCurrentValue`
    /// dans le hero global UNIQUEMENT pour affichage cosmétique quand l'utilisateur
    /// a activé `investmentsIncludeCashInTotal` — JAMAIS pour le calcul de variation%.
    var portfolioTotalCash: Double {
        accounts.reduce(0) { $0 + $1.cashBalance }
    }

    private func assetTypeDisplayName(_ raw: String) -> String {
        InvestmentAssetType(rawValue: raw)?.label ?? raw.capitalized
    }

    // MARK: - AXE J Phase 2 — Évolutions par compte / par position

    /// Calcule l'évolution d'un compte spécifique sur la plage sélectionnée.
    /// Même algo que `recomputePortfolioEvolution` mais restreint aux positions du compte.
    func computeAccountEvolution(accountId: Int, range: InvestmentTimeRange) -> [PortfolioEvolutionPoint] {
        let result = computeAccountEvolutionWithDiagnostic(accountId: accountId, range: range)
        return result.points
    }

    /// Diagnostic d'évolution compte : retourne les points + la liste des positions
    /// pour lesquelles on n'a trouvé aucun cours historique. Permet à l'UI
    /// d'afficher "X positions sans historique : ABC, DEF, ..." pour que l'user
    /// sache lesquelles synchroniser.
    struct AccountEvolutionResult {
        let points: [PortfolioEvolutionPoint]
        let positionsWithoutHistory: [InvestmentPosition]
    }

    func computeAccountEvolutionWithDiagnostic(
        accountId: Int, range: InvestmentTimeRange
    ) -> AccountEvolutionResult {
        let positions = repository.fetchPositions(accountId: accountId)
        guard !positions.isEmpty else {
            return AccountEvolutionResult(points: [], positionsWithoutHistory: [])
        }

        let cutoff = range.startDate
        // historyByPositionId : on indexe par position.id (pas par ticker) car
        // 2 positions peuvent avoir le même ticker (rare mais possible).
        var historyByPositionId: [Int: [InvestmentPricePoint]] = [:]
        var positionsWithoutHistory: [InvestmentPosition] = []

        for position in positions {
            // Essaie plusieurs identifiers : ISIN > ticker > rien.
            // Cohérent avec le loadCachedHistory de PositionDetailView.
            let candidates = [position.isin, position.ticker].filter { !$0.isEmpty }
            var found: [InvestmentPricePoint] = []
            for candidate in candidates {
                let history = repository.fetchPriceHistory(identifier: candidate)
                    .sorted { $0.date < $1.date }
                    .filter { point in
                        guard let cutoff else { return true }
                        return point.date >= cutoff
                    }
                if !history.isEmpty {
                    found = history
                    break
                }
            }
            // Fallback : symbole résolu via la dernière trace de sync (ex:
            // ISIN FR0011871110 → PUST.PA stocké sous PUST.PA)
            if found.isEmpty {
                if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: candidates),
                   trace.status == .success {
                    for symbol in trace.symbolsTried {
                        let history = repository.fetchPriceHistory(identifier: symbol)
                            .sorted { $0.date < $1.date }
                            .filter { point in
                                guard let cutoff else { return true }
                                return point.date >= cutoff
                            }
                        if !history.isEmpty {
                            found = history
                            break
                        }
                    }
                }
            }
            if found.isEmpty {
                positionsWithoutHistory.append(position)
            } else {
                historyByPositionId[position.id] = found
            }
        }

        guard !historyByPositionId.isEmpty else {
            return AccountEvolutionResult(points: [], positionsWithoutHistory: positionsWithoutHistory)
        }

        let allDates = Set(historyByPositionId.values.flatMap { $0.map(\.date) }).sorted()
        var lastKnownPrice: [Int: Double] = [:]
        var points: [PortfolioEvolutionPoint] = []

        for date in allDates {
            var total: Double = 0
            for position in positions {
                if let history = historyByPositionId[position.id],
                   let latestBeforeDate = history.last(where: { $0.date <= date }) {
                    lastKnownPrice[position.id] = latestBeforeDate.close
                }
                let price = lastKnownPrice[position.id] ?? position.averageBuyPrice
                total += position.quantity * price
            }
            points.append(PortfolioEvolutionPoint(date: date, value: total))
        }

        return AccountEvolutionResult(points: points, positionsWithoutHistory: positionsWithoutHistory)
    }

    /// Évolution du cours d'une position (multiplie par qty pour avoir la valeur de la position).
    /// Si `multiplyByQuantity` = false, renvoie le cours brut (utile pour comparer entrée/sortie).
    func computePositionEvolution(ticker: String,
                                  range: InvestmentTimeRange,
                                  quantity: Double = 1.0) -> [PortfolioEvolutionPoint] {
        let history = repository.fetchPriceHistory(identifier: ticker)
            .sorted { $0.date < $1.date }
        let cutoff = range.startDate
        return history
            .filter { point in
                guard let cutoff else { return true }
                return point.date >= cutoff
            }
            .map { PortfolioEvolutionPoint(date: $0.date, value: $0.close * quantity) }
    }

    /// Allocation par type d'actif au sein d'un compte (pour le donut sur AccountDetailView).
    func allocationByAssetType(accountId: Int) -> [AllocationSlice] {
        let positions = repository.fetchPositions(accountId: accountId)
        let grouped = Dictionary(grouping: positions, by: { $0.assetType })
        return grouped.map { key, items in
            AllocationSlice(name: assetTypeDisplayName(key),
                            value: items.reduce(0) { $0 + $1.currentValue })
        }
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
    }

    /// Helper public — récupère les positions d'un compte (utilisé par AccountDetailView).
    func fetchPositions(accountId: Int) -> [InvestmentPosition] {
        repository.fetchPositions(accountId: accountId)
    }

    /// Chantier A — wrapper fin de compatibilité (InvestmentPositionDetailView
    /// l'appelle toujours). La logique de sync (routage crypto/Yahoo, skip du
    /// jour, persistance, trace) vit dans `InvestmentAutoSyncService.syncHistory`
    /// SANS load() interne : ici on fait UN SEUL load() final. Les passes batch
    /// (auto-sync, "tout synchroniser") n'appellent plus ce wrapper mais le
    /// service directement — fini le full reload par position (O(N²)).
    func syncMarketHistory(for identifier: String) async {
        isSyncingMarketData = true
        defer { isSyncingMarketData = false }

        let outcome = await InvestmentAutoSyncService.shared.syncHistory(identifier: identifier)

        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        // Les messages détaillés (symboles essayés, source, nb de points) sont
        // déjà écrits dans la trace par le service — on les réutilise tels quels.
        marketStatusMessage = InvestmentSyncTraceStore.fetch(identifier: clean)?.message
            ?? outcome.shortLabel

        if !clean.isEmpty {
            marketHistory = repository.fetchPriceHistory(identifier: clean)
        }
        load()
    }

    private func detectSeparator(_ line: String) -> Character {
        let candidates: [(Character, Int)] = [
            (";", line.components(separatedBy: ";").count),
            (",", line.components(separatedBy: ",").count),
            ("\t", line.components(separatedBy: "\t").count)
        ]
        return candidates.max(by: { $0.1 < $1.1 })?.0 ?? ";"
    }

    private func parseCSVLine(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                inQuotes.toggle()
            } else if c == separator && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            i = line.index(after: i)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private func mapAssetType(from quoteType: String?) -> InvestmentAssetType {
        let normalized = (quoteType ?? "").uppercased()
        if normalized.contains("ETF") { return .etf }
        if normalized.contains("CRYPTO") { return .crypto }
        if normalized.contains("FUND") { return .fund }
        if normalized.contains("BOND") { return .bond }
        return .stock
    }
}

struct InvestmentCSVMapping {
    var isin: String
    var quantity: String
    var averageBuyPrice: String
    var purchaseDate: String
}

enum InvestmentCSVDateStrategy {
    case requireDate
    case useToday
    case useAccountOpeningDate(Date)
}

enum InvestmentCSVSourceProfile: String, CaseIterable {
    case generic = "Générique"
    case boursobank = "BoursoBank"
}
