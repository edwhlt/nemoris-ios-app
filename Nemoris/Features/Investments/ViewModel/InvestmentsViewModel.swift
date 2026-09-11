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
    /// `LocalizedStringResource`, not `String` — mirrors
    /// `InvestmentSyncTraceStore.Entry.message`, for the same reason.
    var marketStatusMessage: LocalizedStringResource?

    // state for the chart dashboard
    /// Time range selected for the evolution chart.
    var selectedTimeRange: InvestmentTimeRange = .threeMonth
    /// Computed evolution of the global portfolio over the selected range.
    var portfolioEvolution: [PortfolioEvolutionPoint] = []
    /// Set when the 1D range is selected but no position has intraday quotes: the
    /// curve is then deliberately empty and the UI shows this explanation rather
    /// than a line fabricated from daily closes.
    var oneDayUnavailableNote: String?
    /// Positions excluded from `portfolioEvolution` for lack of prices over the
    /// selected range (`PortfolioEvolutionBuilder.unpricedPositionIds`).
    /// Restricts `portfolioVariationBasisValue` to the same positions as
    /// `portfolioStartValue` — otherwise a position without history counts in the
    /// current value but not in the starting point, artificially inflating the
    /// displayed variation %. Two calculation bases must never diverge.
    var portfolioPositionsWithoutHistory: [InvestmentPosition] = []
    /// UI toggle: shows allocation by type or by account.
    var allocationGroupByAccount: Bool = false
    /// Cache of ALL positions of ALL accounts (loaded in `load()`).
    /// The single source for every aggregate computation (portfolio total,
    /// allocations, dashboard stats), instead of `account.currentValue`, which is
    /// never resynced when positions are updated.
    var allPositions: [InvestmentPosition] = []

    /// 1-month sparkline per account (id → points), shown in the dashboard's
    /// account list (Apple Stocks style). Computed at the end of `load()` from the
    /// PriceHistoryCache (RAM) — negligible cost.
    var accountSparklines: [Int: [PortfolioEvolutionPoint]] = [:]

    private let repository: InvestmentRepository

    /// The default value targets the app's own database: no call site changes.
    /// Tests inject a temporary database.
    init(store: SQLiteStore = SQLiteStore()) {
        repository = InvestmentRepository(store: store)
    }
    private let marketDataService = InvestmentMarketDataService()

    var selectedAccount: InvestmentAccount? {
        guard let selectedAccountId else { return nil }
        return accounts.first(where: { $0.id == selectedAccountId })
    }

    var dashboard: InvestmentDashboardStats {
        // everything derived from allPositions (the real state) instead of
        // account.currentValue (a cache never resynced, which stayed at 0).
        let totalValuation = allPositions.reduce(0) { $0 + $1.currentValue }
        let totalInvested = allPositions.reduce(0) { $0 + $1.investedAmount }

        let byAsset = Dictionary(grouping: allPositions) { $0.assetType }
            .map { key, values in
                InvestmentAllocationItem(name: key, value: values.reduce(0) { $0 + $1.currentValue })
            }
            .sorted { $0.value > $1.value }

        // For byAccount: sum of each account's positions (not account.currentValue)
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
                // Forced fr_FR locale: the ViewModel has no access to the SwiftUI
                // environment here — see the matching comment in InsightEngine.swift.
                return InvestmentAllocationItem(name: account.openedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLocalization.locale)), value: val)
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
        // loads the global cache of every position of every account
        // (single source for dashboard.totalValuation, allocations, hero, etc.)
        allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }
        // refreshes the evolution for the chart dashboard
        recomputePortfolioEvolution()
        // 1-month sparkline per account for the dashboard list.
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

    /// Loads a CSV of positions.
    ///
    /// Goes through `CSVParser`, the SHARED reader (quoted fields with escaped
    /// `""`, separator detection that handles quotes).
    ///
    /// What stays SPECIFIC to this module is the column semantics (ISIN /
    /// quantity / average cost, not date / amount / label): it's a different
    /// question put to the user, so it keeps its own screen.
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

        /// Goes through the SHARED parser: it handles "1,234.56" (a blind
        /// comma → dot replacement would produce "1.234.56", hence `nil`), the
        /// non-breaking space of thousands separators and accounting negatives in
        /// parentheses.
        func parseAmount(_ raw: String) -> Double? {
            // Decimal convention inferred from the value: a dot AFTER the last comma
            // signals an English-style format.
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

    /// Computes the total portfolio's evolution over the selected range.
    /// For each date covered by one of the positions' price history, the total
    /// valuation = Σ (qty × close(ticker, date)), forward- and back-filled with
    /// each position's own prices — never with its average cost.
    ///
    /// Accounts without any synced history have no real evolution: the function
    /// returns an empty array and the EvolutionChart shows a placeholder.
    func recomputePortfolioEvolution() {
        // 1. Get ALL positions of ALL accounts (not just selectedAccountId)
        let allPositions = accounts.flatMap { repository.fetchPositions(accountId: $0.id) }
        guard !allPositions.isEmpty else {
            portfolioEvolution = []
            portfolioPositionsWithoutHistory = []
            return
        }

        // 2. Histories per POSITION (not per ticker) through the robust resolution
        //    ISIN → ticker → symbol resolved by the last sync. Looking up by
        //    `position.ticker` alone would leave the GLOBAL chart empty whenever the
        //    history is stored under the ISIN or a resolved symbol (e.g. ISIN →
        //    EWLD.PA via OpenFIGI), while the account/position screens show it.
        // 3. Aggregation delegated to PortfolioEvolutionBuilder: REGULAR time grid,
        //    back/forward-fill with the position's prices, and above all NO fallback
        //    to the average cost (a value on another scale, which produces a
        //    sawtooth curve).
        let inputs = allPositions.map { position in
            PortfolioSeriesInput(
                positionId: position.id,
                quantity: position.quantity,
                history: PositionHistoryResolver.seriesHistory(for: position, range: selectedTimeRange)
            )
        }

        // 1D without ANY intraday quote: draw nothing.
        //
        // Otherwise the builder would compose a curve from DAILY closes over a 24 h
        // window — at best a flat line, at worst two steps — presented as the
        // current day. A clear message beats a curve fabricated at another
        // granularity.
        if selectedTimeRange == .oneDay {
            let withIntraday = allPositions.filter { !PositionHistoryResolver.intradaySeries(for: $0).isEmpty }.count
            if withIntraday == 0 && !allPositions.isEmpty {
                portfolioEvolution = []
                portfolioPositionsWithoutHistory = allPositions
                oneDayUnavailableNote = "Aucun cours intrajournalier disponible pour ce portefeuille. Les titres à valeur liquidative quotidienne (fonds, ETF peu liquides) n'en publient pas ; les autres arrivent à la prochaine synchronisation."
                return
            }
            oneDayUnavailableNote = nil
        } else {
            oneDayUnavailableNote = nil
        }

        let result = PortfolioEvolutionBuilder.build(inputs: inputs, range: selectedTimeRange)
        portfolioEvolution = result.points
        portfolioPositionsWithoutHistory = allPositions.filter { result.unpricedPositionIds.contains($0.id) }
    }

    /// Allocation by asset type (all positions) — for the donut chart.
    /// Uses the `allPositions` cache (instead of fetching the database on every render).
    var allocationByAssetType: [AllocationSlice] {
        Dictionary(grouping: allPositions, by: { InvestmentAssetType.canonicalKey(for: $0.assetType) })
            .map { key, positions in
                AllocationSlice(name: assetTypeDisplayName(key),
                                value: positions.reduce(0) { $0 + $1.currentValue })
            }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    /// Allocation by account — for the donut chart in "by account" mode.
    /// Uses the `allPositions` cache rather than `account.currentValue` (which
    /// stays at 0 and would make the section disappear).
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

    /// Returns the portfolio's value at the start of the time range (to compute
    /// the variation shown in the hero card). Nil without history.
    var portfolioStartValue: Double? {
        portfolioEvolution.first?.value
    }

    /// Current total valuation = sum of the `currentValue` of every position of
    /// every account, from the `allPositions` cache (`account.currentValue` is
    /// never synced and stays at 0).
    var portfolioCurrentValue: Double {
        allPositions.reduce(0) { $0 + $1.currentValue }
    }

    /// Comparison basis for the hero card's variation % — restricted to the
    /// positions actually valued in `portfolioEvolution` (hence in
    /// `portfolioStartValue`). Use it instead of `portfolioCurrentValue` as
    /// `variationBasisValue`; otherwise a position without history over the
    /// selected range counts on one side and not the other, artificially
    /// inflating the %.
    var portfolioVariationBasisValue: Double {
        guard !portfolioPositionsWithoutHistory.isEmpty else { return portfolioCurrentValue }
        let excludedIds = Set(portfolioPositionsWithoutHistory.map(\.id))
        return allPositions
            .filter { !excludedIds.contains($0.id) }
            .reduce(0) { $0 + $1.currentValue }
    }

    /// Total cash across all accounts. Added to `portfolioCurrentValue` in the
    /// global hero ONLY for display, when the user has enabled
    /// `investmentsIncludeCashInTotal` — NEVER for the variation % computation.
    var portfolioTotalCash: Double {
        accounts.reduce(0) { $0 + $1.cashBalance }
    }

    private func assetTypeDisplayName(_ raw: String) -> String {
        InvestmentAssetType(looselyMatching: raw)?.label ?? raw.capitalized
    }

    // MARK: - Evolution per account / per position

    /// Computes a specific account's evolution over the selected range.
    /// Same algorithm as `recomputePortfolioEvolution`, restricted to the account's positions.
    func computeAccountEvolution(accountId: Int, range: InvestmentTimeRange) -> [PortfolioEvolutionPoint] {
        let result = computeAccountEvolutionWithDiagnostic(accountId: accountId, range: range)
        return result.points
    }

    /// Account evolution diagnostic: returns the points + the positions for which
    /// no historical price was found. Lets the UI show "X positions without
    /// history: ABC, DEF, ..." so the user knows which ones to sync.
    struct AccountEvolutionResult {
        let points: [PortfolioEvolutionPoint]
        let positionsWithoutHistory: [InvestmentPosition]
        /// Set on 1D when no position of the account has intraday quotes: the curve
        /// is empty ON PURPOSE (see the same guard at the global level); the UI must
        /// show this explanation.
        var oneDayUnavailableNote: String? = nil
    }

    func computeAccountEvolutionWithDiagnostic(
        accountId: Int, range: InvestmentTimeRange
    ) -> AccountEvolutionResult {
        let positions = repository.fetchPositions(accountId: accountId)
        guard !positions.isEmpty else {
            return AccountEvolutionResult(points: [], positionsWithoutHistory: [])
        }

        // Same engine as the global level (regular grid, never the average cost) —
        // parent and child cannot diverge, neither on identifier resolution nor on
        // the aggregation algorithm.
        // Same guard as the global level: on 1D without any continuous quote, don't
        // fabricate a curve from daily closes.
        if range == .oneDay, positions.allSatisfy({ PositionHistoryResolver.intradaySeries(for: $0).isEmpty }) {
            return AccountEvolutionResult(
                points: [], positionsWithoutHistory: [],
                oneDayUnavailableNote: "Aucun cours intrajournalier disponible pour ce compte. Les titres à valeur liquidative quotidienne n'en publient pas ; les autres arrivent à la prochaine synchronisation."
            )
        }

        let inputs = positions.map { position in
            PortfolioSeriesInput(
                positionId: position.id,
                quantity: position.quantity,
                history: PositionHistoryResolver.seriesHistory(for: position, range: range)
            )
        }
        let result = PortfolioEvolutionBuilder.build(inputs: inputs, range: range)
        let withoutHistory = positions.filter { result.unpricedPositionIds.contains($0.id) }
        return AccountEvolutionResult(points: result.points, positionsWithoutHistory: withoutHistory)
    }

    /// Evolution of a position's price (multiplied by qty to get the position's
    /// value). With `multiplyByQuantity` = false, returns the raw price (useful to
    /// compare entry/exit).
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

    /// Allocation by asset type within an account (for the donut on AccountDetailView).
    func allocationByAssetType(accountId: Int) -> [AllocationSlice] {
        let positions = repository.fetchPositions(accountId: accountId)
        let grouped = Dictionary(grouping: positions, by: { InvestmentAssetType.canonicalKey(for: $0.assetType) })
        return grouped.map { key, items in
            AllocationSlice(name: assetTypeDisplayName(key),
                            value: items.reduce(0) { $0 + $1.currentValue })
        }
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
    }

    /// Public helper — fetches an account's positions (used by AccountDetailView).
    func fetchPositions(accountId: Int) -> [InvestmentPosition] {
        repository.fetchPositions(accountId: accountId)
    }

    /// Thin wrapper (InvestmentPositionDetailView still calls it). The sync logic
    /// (crypto/Yahoo routing, same-day skip, persistence, trace) lives in
    /// `InvestmentAutoSyncService.syncHistory` WITHOUT any internal load(): a
    /// SINGLE final load() happens here. Batch passes (auto-sync, "sync all")
    /// call the service directly, so there is no full reload per position.
    func syncMarketHistory(for identifier: String) async {
        isSyncingMarketData = true
        defer { isSyncingMarketData = false }

        let outcome = await InvestmentAutoSyncService.shared.syncHistory(identifier: identifier)
        InvestmentAutoSyncService.shared.recordOutcome(identifier: identifier, outcome: outcome)

        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        // The detailed messages (symbols tried, source, number of points) are
        // already written to the trace by the service — reused as-is.
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
