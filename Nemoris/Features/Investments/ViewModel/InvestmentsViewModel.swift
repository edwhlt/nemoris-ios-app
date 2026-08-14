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

    // état pour le nouveau dashboard graphique
    /// Plage temporelle sélectionnée pour le chart d'évolution.
    var selectedTimeRange: InvestmentTimeRange = .threeMonth
    /// Évolution calculée du portefeuille global sur la plage sélectionnée.
    var portfolioEvolution: [PortfolioEvolutionPoint] = []
    /// Renseigné quand la plage 1J est sélectionnée mais qu'aucune position n'a
    /// de cotation intrajournalière : la courbe est alors volontairement vide
    /// et l'UI affiche cette explication plutôt qu'une ligne fabriquée à partir
    /// de clôtures quotidiennes.
    var oneDayUnavailableNote: String?
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

    private let repository: InvestmentRepository

    /// La valeur par défaut vise la base de l'application : aucun site d'appel
    /// ne change. Les tests injectent une base temporaire.
    init(store: SQLiteStore = SQLiteStore()) {
        repository = InvestmentRepository(store: store)
    }
    private let marketDataService = InvestmentMarketDataService()

    var selectedAccount: InvestmentAccount? {
        guard let selectedAccountId else { return nil }
        return accounts.first(where: { $0.id == selectedAccountId })
    }

    var dashboard: InvestmentDashboardStats {
        // tout dérivé de allPositions (vrai état) au lieu de
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
                // Locale forcée fr_FR : le ViewModel n'a pas accès à l'environnement
                // SwiftUI ici — cf. commentaire équivalent dans InsightEngine.swift.
                return InvestmentAllocationItem(name: account.openedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "fr_FR"))), value: val)
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
        // charge le cache global de toutes les positions de tous les comptes
        // (source unique pour dashboard.totalValuation, allocations, hero, etc.)
        allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }
        // refresh l'évolution pour le dashboard graphique
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

    /// Charge un CSV de positions.
    ///
    /// ⚠️ Passe par `CSVParser`, le lecteur COMMUN. Ce module avait le sien
    /// — troisième détection de séparateur et troisième découpage de cellules
    /// de l'app — et il était strictement moins bon : son `inQuotes.toggle()`
    /// à chaque guillemet cassait les guillemets échappés (`""` à l'intérieur
    /// d'un champ), et sa détection de séparateur ne regardait que la première
    /// ligne sans gérer les guillemets.
    ///
    /// Ce qui reste PROPRE à ce module est la sémantique des colonnes
    /// (ISIN / quantité / PRU, et non date / montant / libellé) : c'est une
    /// autre question posée à l'utilisateur, elle garde donc son écran.
    func loadCSV(content: String) {
        guard let grid = CSVParser.parse(content: content), !grid.headers.isEmpty else {
            csvErrors = ["Fichier CSV vide ou illisible"]
            return
        }
        csvHeaders = grid.headers
        csvRows = grid.rows
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

        /// ⚠️ Passe par le parseur COMMUN. La version locale remplaçait
        /// aveuglément toutes les virgules par des points : « 1,234.56 »
        /// devenait « 1.234.56 », donc `nil`, et la ligne était rejetée comme
        /// « quantité/prix invalides ». Elle ne gérait pas non plus l'espace
        /// insécable des séparateurs de milliers ni les négatifs comptables
        /// entre parenthèses.
        func parseAmount(_ raw: String) -> Double? {
            // Convention décimale déduite de la valeur : un point APRÈS la
            // dernière virgule signe un format anglo-saxon.
            let anglo = raw.lastIndex(of: ".").map { dot in
                raw.lastIndex(of: ",").map { $0 < dot } ?? true
            } ?? false
            return CSVParser.parseAmount(raw, decimal: anglo ? "." : ",")
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

    // MARK: - Portfolio evolution (Niveau Global)

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
        // 2. Agrégation déléguée à PortfolioEvolutionBuilder : grille temporelle
        //    RÉGULIÈRE, back/forward-fill avec les cours de la position, et
        //    surtout AUCUN repli sur le PRU (qui injectait une valeur d'une
        //    autre échelle et produisait les "dents de scie").
        let inputs = allPositions.map { position in
            PortfolioSeriesInput(
                positionId: position.id,
                quantity: position.quantity,
                history: seriesHistory(for: position, range: selectedTimeRange)
            )
        }

        // ⚠️ 1J sans AUCUNE cotation intrajournalière : ne rien tracer.
        //
        // Sinon le builder compose une courbe à partir de clôtures
        // QUOTIDIENNES sur une fenêtre de 24 h — au mieux une ligne plate, au
        // pire deux paliers — présentée comme la journée en cours. C'est la
        // version agrégée du « 1J n'affiche que 2 points ». Un message clair
        // vaut mieux qu'une courbe fabriquée dans une autre granularité.
        if selectedTimeRange == .oneDay {
            let withIntraday = allPositions.filter { !intradaySeries(for: $0).isEmpty }.count
            if withIntraday == 0 && !allPositions.isEmpty {
                portfolioEvolution = []
                oneDayUnavailableNote = "Aucun cours intrajournalier disponible pour ce portefeuille. Les titres à valeur liquidative quotidienne (fonds, ETF peu liquides) n'en publient pas ; les autres arrivent à la prochaine synchronisation."
                return
            }
            oneDayUnavailableNote = nil
        } else {
            oneDayUnavailableNote = nil
        }

        portfolioEvolution = PortfolioEvolutionBuilder
            .build(inputs: inputs, range: selectedTimeRange)
            .points
    }

    /// Historique à agréger pour une position sur une plage donnée.
    /// Granularité adaptée : la vue 1J utilise la série INTRADAY 30 min (la série
    /// quotidienne n'a qu'un point sur 24 h glissantes). Si l'intraday manque
    /// pour cette position, on retombe sur son QUOTIDIEN (non filtré) : le
    /// builder la maintiendra à plat sur son dernier cours réel — jamais sur le PRU.
    private func seriesHistory(for position: InvestmentPosition,
                               range: InvestmentTimeRange) -> [InvestmentPricePoint] {
        if range == .oneDay {
            let intraday = intradaySeries(for: position)
            if !intraday.isEmpty { return intraday }
            // Repli quotidien conservé UNIQUEMENT quand d'autres positions ont
            // de l'intraday : le builder maintient alors celle-ci à plat sur son
            // dernier cours réel, ce qui est correct (elle n'a pas bougé). Si
            // AUCUNE position n'a d'intraday, l'appelant coupe court et
            // n'affiche pas de courbe du tout.
            return resolveHistory(for: position, cutoff: nil, resolution: .daily)
        }
        return resolveHistory(for: position, cutoff: range.startDate, resolution: .daily)
    }

    /// Série intrajournalière d'une position, bornée aux dernières 24 h COTÉES.
    ///
    /// ⚠️ Pas de `cutoff: range.startDate` : une fenêtre calée sur `Date()` est
    /// VIDE dès qu'on consulte hors séance (le samedi, la dernière cotation du
    /// vendredi a plus de 24 h). On lit la série entière (rétention 96 h) puis
    /// on garde les dernières 24 h ancrées sur le dernier point réel.
    private func intradaySeries(for position: InvestmentPosition) -> [InvestmentPricePoint] {
        resolveHistory(for: position, cutoff: nil, resolution: .intraday30m)
            .lastQuotedWindow()
    }

    /// Résolution ROBUSTE de l'historique de cours d'une position.
    /// Essaie dans l'ordre : ISIN → ticker → symboles retenus par la dernière
    /// synchro réussie (ex. un ISIN résolu en "PUST.PA" via OpenFIGI est stocké
    /// sous ce symbole). Source unique utilisée par TOUS les niveaux de chart
    /// (global, compte, position) — sinon le parent peut rester vide alors que
    /// l'enfant s'affiche.
    private func resolveHistory(for position: InvestmentPosition, cutoff: Date?,
                                resolution: PriceResolution = .daily) -> [InvestmentPricePoint] {
        func load(_ identifier: String) -> [InvestmentPricePoint] {
            PriceHistoryCache.shared.fetch(identifier: identifier, resolution: resolution)
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
    /// utilise le cache `allPositions` (au lieu de fetcher la DB à chaque render).
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
    /// utilise le cache `allPositions` au lieu de `account.currentValue`
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
    /// d'afficher "X positions sans historique : ABC, DEF, ..." pour que l'utilisateur
    /// sache lesquelles synchroniser.
    struct AccountEvolutionResult {
        let points: [PortfolioEvolutionPoint]
        let positionsWithoutHistory: [InvestmentPosition]
        /// Renseigné en 1J quand aucune position du compte n'a de cotation
        /// intrajournalière : la courbe est vide À DESSEIN (cf. le même garde
        /// au niveau global), l'UI doit afficher cette explication.
        var oneDayUnavailableNote: String? = nil
    }

    func computeAccountEvolutionWithDiagnostic(
        accountId: Int, range: InvestmentTimeRange
    ) -> AccountEvolutionResult {
        let positions = repository.fetchPositions(accountId: accountId)
        guard !positions.isEmpty else {
            return AccountEvolutionResult(points: [], positionsWithoutHistory: [])
        }

        // Même moteur que le niveau global (grille régulière, jamais de PRU) —
        // parent et enfant ne peuvent plus diverger, ni sur la résolution des
        // identifiants, ni sur l'algorithme d'agrégation.
        // Même garde qu'au niveau global : en 1J sans aucune cotation en
        // continu, ne pas fabriquer de courbe à partir de clôtures quotidiennes.
        if range == .oneDay, positions.allSatisfy({ intradaySeries(for: $0).isEmpty }) {
            return AccountEvolutionResult(
                points: [], positionsWithoutHistory: [],
                oneDayUnavailableNote: "Aucun cours intrajournalier disponible pour ce compte. Les titres à valeur liquidative quotidienne n'en publient pas ; les autres arrivent à la prochaine synchronisation."
            )
        }

        let inputs = positions.map { position in
            PortfolioSeriesInput(
                positionId: position.id,
                quantity: position.quantity,
                history: seriesHistory(for: position, range: range)
            )
        }
        let result = PortfolioEvolutionBuilder.build(inputs: inputs, range: range)
        let withoutHistory = positions.filter { result.unpricedPositionIds.contains($0.id) }
        return AccountEvolutionResult(points: result.points, positionsWithoutHistory: withoutHistory)
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
