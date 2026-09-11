import Foundation

enum AccountType: String, CaseIterable {
    case courant  = "COURANT"
    case epargne  = "EPARGNE"
    case differe  = "DIFFERE"
    case autre    = "AUTRE"

    var label: String {
        switch self {
        case .courant: return "Courant"
        case .epargne: return "Épargne"
        case .differe: return "Différé"
        case .autre:   return "Autre"
        }
    }
}

struct Account: Identifiable, Hashable {
    let id: Int
    var name: String
    var type: String = "COURANT"
    /// v51 — exclut ce compte de tous les calculs agrégés (cumuls par catégorie,
    /// budget, dashboard, coach IA, widget). Ses propres transactions restent
    /// consultables normalement sur l'écran du compte. Usage type : compte de
    /// remboursements santé/mutuelle qu'on ne veut pas voir peser sur le budget.
    var excludedFromAggregates: Bool = false

    var accountType: AccountType { AccountType(rawValue: type) ?? .courant }
}

extension Array where Element == Account {
    /// Accounts grouped by type (Checking → Savings → Deferred → Other),
    /// sorted alphabetically within each group. Empty groups are omitted.
    var groupedByType: [(type: AccountType, accounts: [Account])] {
        AccountType.allCases.compactMap { type in
            let group = self.filter { $0.accountType == type }
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return group.isEmpty ? nil : (type, group)
        }
    }
}

struct Category: Identifiable, Hashable {
    let id: Int
    var name: String
    var parentId: Int? = nil
    var icon: String? = nil

    /// SF Symbol to use in UI — falls back to a sensible default when no icon is stored.
    var displayIcon: String {
        icon ?? Self.defaultIcon(for: name, isParent: parentId == nil)
    }

    private static func defaultIcon(for name: String, isParent: Bool) -> String {
        let n = name.lowercased()
        if n.contains("aliment") || n.contains("supermarché") || n.contains("épicerie") { return "cart.fill" }
        if n.contains("restaurant") || n.contains("bar") || n.contains("café") { return "fork.knife" }
        if n.contains("carburant") || n.contains("essence") { return "fuelpump.fill" }
        if n.contains("transport") || n.contains("tram") || n.contains("bus") || n.contains("navigo") { return "tram.fill" }
        if n.contains("voiture") || n.contains("auto") { return "car.fill" }
        if n.contains("loyer") || n.contains("logement") || n.contains("charges") { return "house.fill" }
        if n.contains("internet") || n.contains("téléphone") || n.contains("mobile") { return "wifi" }
        if n.contains("énergie") || n.contains("électricité") || n.contains("edf") { return "bolt.fill" }
        if n.contains("médecin") || n.contains("santé") || n.contains("docteur") { return "stethoscope" }
        if n.contains("pharmacie") || n.contains("médicament") { return "pills.fill" }
        if n.contains("cinéma") || n.contains("spectacle") || n.contains("film") { return "film.fill" }
        if n.contains("sport") || n.contains("fitness") { return "figure.run" }
        if n.contains("abonnement") { return "repeat" }
        if n.contains("loisir") || n.contains("culture") || n.contains("jeu") { return "gamecontroller.fill" }
        if n.contains("vêtement") || n.contains("shopping") || n.contains("mode") { return "bag.fill" }
        if n.contains("voyage") || n.contains("avion") || n.contains("hôtel") { return "airplane" }
        if n.contains("salaire") || n.contains("revenu") { return "banknote.fill" }
        if n.contains("remboursement") { return "arrow.uturn.left.circle.fill" }
        if n.contains("banque") || n.contains("finance") || n.contains("épargne") { return "building.columns.fill" }
        if n.contains("divers") || n.contains("autre") { return "ellipsis.circle.fill" }
        return isParent ? "folder.fill" : "tag.fill"
    }
}

/// Node of the category tree, built in memory from the flat list.
struct CategoryNode: Identifiable {
    let category: Category
    var children: [CategoryNode]

    var id: Int { category.id }
    var isLeaf: Bool { children.isEmpty }

    /// Sort criterion for categories in the tree.
    enum SortMode {
        /// Alphabetical order (case-insensitive) at each level.
        case alphabetical
        /// Creation order (ascending id) at each level.
        case creation
    }

    /// Builds the forest (list of roots) from a flat list of Category.
    static func buildForest(from flat: [Category], sort: SortMode = .alphabetical) -> [CategoryNode] {
        var nodeMap: [Int: CategoryNode] = [:]
        for cat in flat {
            nodeMap[cat.id] = CategoryNode(category: cat, children: [])
        }
        // Pass 1: assign all children into nodeMap
        for cat in flat {
            guard let parentId = cat.parentId else { continue }
            let child = nodeMap[cat.id]!
            if var parent = nodeMap[parentId] {
                parent.children.append(child)
                nodeMap[parentId] = parent
            }
        }
        // Pass 2: collect roots AFTER all children have been assigned
        let roots = flat
            .filter { $0.parentId == nil }
            .compactMap { nodeMap[$0.id] }
        return ordered(roots, sort: sort)
            .map { Self.sorted($0, sort: sort) }
    }

    private static func sorted(_ node: CategoryNode, sort: SortMode) -> CategoryNode {
        var n = node
        n.children = ordered(node.children.map { sorted($0, sort: sort) }, sort: sort)
        return n
    }

    private static func ordered(_ nodes: [CategoryNode], sort: SortMode) -> [CategoryNode] {
        switch sort {
        case .alphabetical:
            return nodes.sorted { $0.category.name.localizedCaseInsensitiveCompare($1.category.name) == .orderedAscending }
        case .creation:
            return nodes.sorted { $0.category.id < $1.category.id }
        }
    }

    /// Returns all IDs in the subtree (self + descendants).
    func allIds() -> [Int] {
        [category.id] + children.flatMap { $0.allIds() }
    }

    /// Pre-order traversal (self, then each subtree) with the depth of each
    /// node — for surfaces that can't render a real tree (a `Picker`'s menu)
    /// but can still convey hierarchy via indentation.
    func flattened(depth: Int = 0) -> [(node: CategoryNode, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }

    /// Same traversal over a forest (list of roots).
    static func flattenedForest(_ roots: [CategoryNode]) -> [(node: CategoryNode, depth: Int)] {
        roots.flatMap { $0.flattened() }
    }
}

struct Tag: Identifiable, Hashable {
    let id: Int
    var name: String
    var color: String?  // Hex without #, e.g. "8B5CF6"; nil = default purple
}

/// Type of a tier — drives UI adaptation and engine routing.
enum TierType: String, Codable, CaseIterable, Identifiable {
    case merchant        // Business (Carrefour, Apple, etc.)
    case contact         // Individual (P2P, "Dad", "Marie")
    case `internal`      // Transfer between the user's own accounts
    case organization    // CAF, CPAM, employer, school

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .merchant:     return "Commerce"
        case .contact:      return "Contact"
        case .internal:     return "Compte interne"
        case .organization: return "Organisation"
        }
    }

    var systemIcon: String {
        switch self {
        case .merchant:     return "building.2.fill"
        case .contact:      return "person.crop.circle.fill"
        case .internal:     return "arrow.left.arrow.right.circle.fill"
        case .organization: return "building.columns.fill"
        }
    }
}

struct Tiers: Identifiable, Hashable {
    let id: Int
    var name: String
    var regex: String?
    var categoryId: Int? = nil
    var linkedCompteId: Int? = nil
    /// Canonical ID on the NemorisEngine side (e.g. "carrefour"). Nil for custom tiers.
    var engineMerchantId: String? = nil
    /// Web domain used to fetch the favicon. Nullable — resolved dynamically
    /// via the engine seed when empty.
    var domain: String? = nil
    // Full-editing fields exposed to the user.
    var address: String? = nil
    var city: String? = nil
    /// ISO 3166-1 alpha-2 country code (e.g. "FR").
    var country: String? = nil
    var groupId: Int? = nil
    /// 1 = manually created by the user (no engine link expected).
    var custom: Bool = false
    /// Free-form note entered by the user.
    var note: String? = nil
    /// Type of the tier (merchant / contact / internal / organization).
    var tierType: TierType = .merchant
    /// Local CNContact identifier (iOS contacts book) if the tier is of type
    /// .contact and was explicitly linked by the user. Used to fetch the
    /// local photo.
    var contactIdentifier: String? = nil
}

struct PayeeGroup: Identifiable, Hashable {
    let id: Int
    var displayName: String
    var engineMerchantId: String?
    var custom: Bool = false
}

struct PaymentType: Identifiable, Hashable {
    let id: Int
    var name: String
    var regex: String?
}

struct FinanceTransaction: Identifiable, Hashable {
    let id: Int
    let accountId: Int
    let tiersId: Int?
    let categoryId: Int?
    let paymentTypeId: Int?
    let remboursementTiersId: Int?
    let tiersName: String
    let categoryName: String
    let paymentTypeName: String
    let remboursementTiersName: String
    let information: String
    /// Raw bank label (filled in on import, nil for manually entered transactions).
    let libelleBrut: String?
    let amount: Double
    let date: Date
}

enum TransactionTypePicker: String, CaseIterable {
    case expense
    case income
}

/// Tri-state of a tag within a multi-selection context.
enum TagSelectionState {
    case all    // every selected item has this tag
    case some   // only some selected items have this tag (indeterminate)
    case none   // no selected item has this tag

    mutating func toggle() {
        switch self {
        case .all:        self = .none
        case .some, .none: self = .all
        }
    }
}

struct TransactionEditDraft: Identifiable {
    var id: Int
    var tiersId: Int?
    var categoryId: Int?
    var paymentTypeId: Int?
    var remboursementTiersId: Int?
    var information: String
    /// Raw bank label — read-only, not editable by the user.
    let libelleBrut: String?
    var amount: Double
    var type: TransactionTypePicker
    var date: Date

    init(from tx: FinanceTransaction) {
        id = tx.id
        tiersId = tx.tiersId
        categoryId = tx.categoryId
        paymentTypeId = tx.paymentTypeId
        remboursementTiersId = tx.remboursementTiersId
        information = tx.information
        libelleBrut = tx.libelleBrut
        amount = tx.amount
        type = tx.amount >= 0 ? .income : .expense
        date = tx.date
    }
}

/// Status of a reimbursement.
enum ReimbursementStatus: String, Codable, CaseIterable, Identifiable {
    case pending  = "PENDING"
    case received = "RECEIVED"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending:  return "En attente"
        case .received: return "Reçu"
        }
    }

    var systemIcon: String {
        switch self {
        case .pending:  return "clock.fill"
        case .received: return "checkmark.circle.fill"
        }
    }
}

/// An expected reimbursement — attached to either a plain transaction OR a
/// Tricount entry (never both, enforced by a CHECK XOR constraint in the
/// database).
struct Reimbursement: Identifiable {
    let id: Int
    let transactionId: Int?
    let tricountEntryId: Int?
    let payeeId: Int
    let payeeName: String
    var status: ReimbursementStatus
    let updatedAt: Date

    /// Signed amount in the original currency (negative = expense, the
    /// common case) — already signed by the query: the raw amount for a
    /// transaction, the personal share signed according to the linked
    /// entry's type for a Tricount reimbursement.
    let amount: Double
    let currency: String
    /// Signed EUR equivalent (nil if conversion is unavailable or already in EUR).
    let eurAmount: Double?

    let originDescription: String
    let originDate: Date

    /// Category of the originating transaction/entry — nil if uncategorized.
    /// Appended at the end with default values so existing construction
    /// sites that don't have this information (Tricount-only reimbursements,
    /// for instance) remain unaffected.
    var categoryId: Int? = nil
    var categoryName: String = ""
    /// PRIMARY payee of the originating transaction (e.g. "Netflix") —
    /// distinct from `payeeName`, which is the one DOING the reimbursing.
    /// Empty on the Tricount side (no equivalent). Used as a display
    /// fallback when `originDescription` is empty (common, since it's a
    /// free-form note field that's often never filled in).
    var originPayeeName: String = ""

    var isTricountOrigin: Bool { tricountEntryId != nil }
    var effectiveEurAmount: Double { eurAmount ?? amount }
    var isConverted: Bool { eurAmount != nil && currency != "EUR" && currency != "" }
    var needsConversion: Bool { currency != "EUR" && currency != "" && eurAmount == nil }
}

/// Reimbursements grouped by the originating expense's category — a view
/// complementary to the payee grouping in `ReimbursementsSheet`.
struct CategoryReimbursementGroup: Identifiable {
    let categoryId: Int?
    let categoryName: String   // "Non catégorisé" if categoryId == nil
    let items: [Reimbursement]
    var id: Int { categoryId ?? -1 }
    var total: Double { items.reduce(0) { $0 + $1.effectiveEurAmount } }
    var transactionCount: Int { items.filter { !$0.isTricountOrigin }.count }
    var tricountCount: Int { items.filter { $0.isTricountOrigin }.count }
}

/// Reimbursements grouped by payee — plain transactions and Tricount entries combined.
struct ReimbursementGroup: Identifiable {
    let payeeId: Int
    let payeeName: String
    let items: [Reimbursement]
    var id: Int { payeeId }
    var total: Double { items.reduce(0) { $0 + $1.effectiveEurAmount } }
    var transactionCount: Int { items.filter { !$0.isTricountOrigin }.count }
    var tricountCount: Int { items.filter { $0.isTricountOrigin }.count }
}

struct MonthlyTotals {
    let month: String   // "2025-01"
    let income: Double
    let expense: Double
}

struct CategoryTotal {
    let category: String
    let parentCategory: String?   // nil if there's no parent category
    let total: Double
}

struct TagTotal: Identifiable {
    let tag: Tag
    let total: Double
    var id: Int { tag.id }
}

struct DashboardStats {
    let totalIncome: Double
    let totalExpense: Double
    let transactionCount: Int
    var netBalance: Double { totalIncome + totalExpense }

    static let empty = DashboardStats(totalIncome: 0, totalExpense: 0, transactionCount: 0)
}

struct TransactionFilter {
    var accountId: Int
    var accountName: String
    var from: Date
    var to: Date
    /// Filtre sur le NOM DU TIERS uniquement (payee). Distinct de
    /// `labelSearchText` depuis la scission des deux champs dans
    /// `TransactionFiltersSheet` — avant, un seul champ matchait l'un OU
    /// l'autre ; désormais les deux, quand renseignés, sont exigés ensemble.
    var payeeSearchText: String = ""
    /// Filtre sur le libellé brut (`transactions.information`) uniquement.
    var labelSearchText: String = ""
    var categoryId: Int = -1
    var categoryName: String = ""
    var tagNames: [String] = []
    var tagFilteredTxIds: Set<Int>? = nil

    var hasActiveFilters: Bool {
        !payeeSearchText.isEmpty || !labelSearchText.isEmpty || categoryId != -1 || tagFilteredTxIds != nil
    }
}

struct SQLQueryResult {
    let columns: [String]
    let rows: [[String]]
}

struct SQLError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PendingTransaction: Identifiable {
    let id = UUID()
    let sourceRowNumber: Int
    let accountId: Int
    var tiersId: Int?
    var mdpId: Int?
    let information: String
    let amount: Double
    let date: Date
    var tiersName: String
    var mdpName: String
}

struct TransactionImportFailure: Identifiable, Hashable {
    let id = UUID()
    let sourceRowNumber: Int
    let information: String
    let amount: Double
    let date: Date
    let reason: String
}

struct TransactionImportResult {
    let insertedCount: Int
    let failures: [TransactionImportFailure]
    /// Created ID for each source row (row number → transaction id).
    ///
    /// Needed to attach data AFTER the insert — free-form metadata in
    /// particular, which references `transactions(id)`. Defaults to empty
    /// so call sites that don't need it are unaffected.
    var insertedIds: [Int: Int] = [:]
}

struct TiersBulkImportResult {
    let insertedCount: Int
    let skippedCount: Int
}

// MARK: - Tricount Models

struct TricountGroup: Identifiable, Equatable, Hashable {
    let id: Int
    let tricountKey: String
    let title: String
    let currency: String
    let myName: String
    let fetchedAt: Date
    let entryCount: Int
}

struct TricountEntry: Identifiable {
    let id: Int
    let groupId: Int
    let sourceUUID: String?
    let sourceUpdatedAt: String?
    let typeTransaction: String
    let whoPaid: String
    let total: Double
    let currency: String
    let localTotal: Double?
    let localCurrency: String?
    let description: String
    let date: Date
    let category: String
    let userCategoryId: Int?
    let userCategoryName: String
    let linkedTransactionId: Int?
}

/// Expense summary for a tag (transactions + Tricount entries)
struct TagExpenseSummary: Identifiable {
    let tag: Tag
    let transactionTotal: Double   // sum of transaction amounts
    let tricountTotal: Double      // sum of Tricount entry totals (absolute value)
    var total: Double { transactionTotal + tricountTotal }
    var id: Int { tag.id }
}

/// A tagged Tricount entry, for display in TagDetailView
struct TaggedTricountEntry: Identifiable {
    let id: Int
    let description: String
    let myShare: Double         // the user's share, in the group's currency
    let currency: String        // the group's currency (e.g. "VND")
    let eurShare: Double?       // EUR equivalent of myShare (nil if the rate is unknown)
    let date: Date
    let whoPaid: String
    let groupTitle: String
    let typeTransaction: String // "NORMAL", "INCOME", "BALANCE", "TRANSFER"

    /// Amount to use for totals: EUR if available, otherwise the original currency.
    var effectiveEurAmount: Double { eurShare ?? myShare }
    var isConverted: Bool { eurShare != nil && currency != "EUR" }
    /// True if the entry is in a foreign currency WITHOUT an available rate → amount not convertible.
    var needsConversion: Bool { currency != "EUR" && currency != "" && eurShare == nil }
    /// True if the entry is an expense (NORMAL) → negative sign in totals.
    var isExpense: Bool { typeTransaction.uppercased() == "NORMAL" }
    /// Signed amount for totals: negative if an expense, positive if income/reimbursement.
    var signedAmount: Double { isExpense ? -effectiveEurAmount : effectiveEurAmount }
}

struct TricountShare: Identifiable {
    let id: Int
    let entryId: Int
    let memberName: String
    let amount: Double
}

struct TricountMemberBalance: Identifiable {
    let memberName: String
    let iOwe: Double    // I owe this person
    let theyOwe: Double // They owe me
    var net: Double { theyOwe - iOwe } // positive = they owe me
    var id: String { memberName }
}

// MARK: - Investments Models

enum InvestmentAccountType: String, CaseIterable {
    case pea = "PEA"
    case cto = "CTO"
    case assuranceVie = "ASSURANCE_VIE"
    case crypto = "CRYPTO"
    case other = "OTHER"

    var label: String {
        switch self {
        case .pea: return "PEA"
        case .cto: return "CTO"
        case .assuranceVie: return "Assurance vie"
        case .crypto: return "Compte crypto"
        case .other: return "Autres comptes titres"
        }
    }
}

enum InvestmentAssetType: String, CaseIterable {
    case stock = "STOCK"
    case etf = "ETF"
    case bond = "BOND"
    case crypto = "CRYPTO"
    case fund = "FUND"

    var label: String {
        switch self {
        case .stock: return "Action"
        case .etf: return "ETF"
        case .bond: return "Obligation"
        case .crypto: return "Crypto"
        case .fund: return "Fonds"
        }
    }

    /// Résolution tolérante d'un `asset_type` brut stocké en base (casse/espaces non garantis —
    /// données legacy ou édition manuelle via la Console SQL). À utiliser PARTOUT où `asset_type`
    /// sert de clé de groupement (allocation, couleur) pour que deux variantes du même type
    /// (ex. "stock" vs "STOCK") ne produisent jamais deux entrées distinctes côté UI.
    ///
    /// Résout AUSSI contre le `label` français (ex. "Action", "Obligation") : une valeur legacy
    /// peut avoir été écrite avec le libellé d'affichage plutôt que le rawValue canonique — sans
    /// ce second essai, "Action" et "STOCK" restent deux clés distinctes qui s'affichent toutes
    /// les deux "Action" (bug réel constaté : deux tranches "Action" dans le donut d'allocation).
    init?(looselyMatching raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let byRawValue = InvestmentAssetType(rawValue: normalized) {
            self = byRawValue
            return
        }
        if let byLabel = InvestmentAssetType.allCases.first(where: { $0.label.uppercased() == normalized }) {
            self = byLabel
            return
        }
        return nil
    }

    /// Clé de groupement canonique pour un `asset_type` brut : le rawValue de l'enum s'il est
    /// reconnu (quelle que soit sa casse/espacement d'origine), sinon la version normalisée
    /// telle quelle — garantit que le groupement et l'affichage retombent toujours sur la même clé.
    static func canonicalKey(for raw: String) -> String {
        InvestmentAssetType(looselyMatching: raw)?.rawValue
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

struct InvestmentAccount: Identifiable, Hashable {
    let id: Int
    var name: String
    var broker: String
    var currency: String
    var accountType: String
    var currentValue: Double       // Σ positions.current_value (derived)
    var investedAmount: Double     // Σ qty × average buy price (derived)
    var openedAt: Date
    /// Cash available on the account (dividends not reinvested, pending
    /// sales, recent deposits). Persisted directly on the row, editable by
    /// the user in the account form.
    var cashBalance: Double = 0

    /// Total account valuation = value of the positions + cash.
    /// This is what should be shown as the account's "real" capital.
    var totalValuation: Double { currentValue + cashBalance }
}

struct InvestmentPosition: Identifiable, Hashable {
    let id: Int
    let accountId: Int
    var assetType: String
    var assetName: String
    var ticker: String
    var isin: String = ""          // 12-char ISIN (FR0000121329) — preferred for sync via OpenFIGI
    var quantity: Double           // DERIVED from orders (Σ BUY - Σ SELL)
    var averageBuyPrice: Double    // DERIVED from orders (weighted average price of the BUYs)
    var currentValue: Double
    var purchaseDate: Date         // date of the FIRST BUY chronologically

    var investedAmount: Double { quantity * averageBuyPrice }
    var pnl: Double { currentValue - investedAmount }

    /// Identifier to prefer for sync: ISIN > ticker. The ISIN resolves
    /// universally to the right tradable symbol via OpenFIGI.
    var bestSyncIdentifier: String {
        !isin.isEmpty ? isin : ticker
    }

    /// True if the position is a crypto asset. Lets the Yahoo sync layer
    /// exclude it (Yahoo also quotes stocks that share the same tickers as
    /// cryptos: FET = a stock, BTC = a BlackRock ETF, ETH = a stock, etc.,
    /// which would corrupt the current_value obtained via LiveSync/CoinGecko).
    var isCryptoAsset: Bool {
        assetType.uppercased() == "CRYPTO"
    }
}

// MARK: - Investment orders (multiple orders per position)

/// Type of an order. MVP: buy, sell, dividend. Splits/mergers are out of scope.
enum InvestmentOrderType: String, CaseIterable, Identifiable {
    case buy = "BUY"
    case sell = "SELL"
    case dividend = "DIV"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .buy:      return "Achat"
        case .sell:     return "Vente"
        case .dividend: return "Dividende"
        }
    }

    var systemIcon: String {
        switch self {
        case .buy:      return "arrow.down.circle.fill"
        case .sell:     return "arrow.up.circle.fill"
        case .dividend: return "dollarsign.circle.fill"
        }
    }
}

/// An investment order = one operation on a position at a given date.
/// Several orders compose a position (qty and average price are derived on the fly).
struct InvestmentOrder: Identifiable, Hashable {
    let id: Int
    let positionId: Int
    var orderType: InvestmentOrderType
    var quantity: Double        // Always positive; the sign is carried by orderType
    var unitPrice: Double       // Unit price at execution (account currency)
    var fees: Double            // Brokerage fees (0 if unknown)
    var executedAt: Date
    var notes: String?
    /// Stable external ID returned by the provider (Binance tradeId,
    /// blockchain txHash). Enables dedup across syncs via a SQL UNIQUE INDEX.
    /// nil for orders entered manually by the user.
    var externalId: String? = nil

    /// Total gross cost (qty × price + fees). For BUY = cash outflow, for SELL = cash inflow.
    var totalCost: Double { quantity * unitPrice + fees }
}

struct InvestmentAllocationItem: Identifiable {
    let name: String
    let value: Double
    var id: String { name }
}

struct InvestmentDashboardStats {
    let totalValuation: Double
    let totalInvested: Double
    let byAssetType: [InvestmentAllocationItem]
    let byAccount: [InvestmentAllocationItem]
    let evolution: [InvestmentAllocationItem]

    var performance: Double { totalValuation - totalInvested }
}

struct InvestmentPricePoint: Identifiable, Hashable, Codable {
    let id: String
    let identifier: String
    let date: Date
    let close: Double
    /// OPENING price of the time step (the candle: a day in `.daily`, a
    /// 30-minute slice in `.intraday30m`). This is the point's "entry
    /// price", which Yahoo and Stooq already provide alongside the close.
    ///
    /// Optional for two reasons:
    ///   - series already in the disk cache don't have this key (the
    ///     synthesized Codable decoding uses `decodeIfPresent` for an
    ///     Optional → existing caches stay readable, otherwise the ENTIRE
    ///     history would be discarded on first decode);
    ///   - CoinGecko's `market_chart` only returns point prices, no OHLC.
    let open: Double?

    /// Explicit init: with `open` as a `let` with no default value, the
    /// synthesized memberwise init would require it at all ~6 construction sites.
    init(id: String, identifier: String, date: Date, close: Double, open: Double? = nil) {
        self.id = id
        self.identifier = identifier
        self.date = date
        self.close = close
        self.open = open
    }
}
