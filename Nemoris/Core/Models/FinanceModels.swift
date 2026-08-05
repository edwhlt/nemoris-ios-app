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

    var accountType: AccountType { AccountType(rawValue: type) ?? .courant }
}

extension Array where Element == Account {
    /// Comptes groupés par type (Courant → Épargne → Différé → Autre),
    /// triés alphabétiquement au sein de chaque groupe. Groupes vides omis.
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

extension Array where Element == Category {
    /// Liste à plat triée hiérarchiquement : chaque parente est immédiatement
    /// suivie de ses sous-catégories. Les sous-cats portent un préfixe `↳ ` pour
    /// matérialiser la hiérarchie dans les Pickers (qui n'ont pas de notion
    /// native d'indentation).
    ///
    /// Tri alphabétique au sein de chaque niveau pour stabilité.
    var hierarchicallySorted: [(category: Category, indentedName: String)] {
        let parents = self.filter { $0.parentId == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var result: [(Category, String)] = []
        for parent in parents {
            result.append((parent, parent.name))
            let children = self.filter { $0.parentId == parent.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for child in children {
                result.append((child, "↳ \(child.name)"))
            }
        }
        // Catégories orphelines (parent_id non-nil mais parent introuvable) :
        // ne pas les perdre — on les ajoute à la fin sans indentation.
        let knownIds = Set(parents.map(\.id))
        let orphans = self.filter { c in
            guard let pid = c.parentId else { return false }
            return !knownIds.contains(pid)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for orphan in orphans {
            result.append((orphan, orphan.name))
        }
        return result
    }
}

/// Nœud de l'arbre des catégories, construit en mémoire depuis la liste plate.
struct CategoryNode: Identifiable {
    let category: Category
    var children: [CategoryNode]

    var id: Int { category.id }
    var isLeaf: Bool { children.isEmpty }

    /// Critère de tri des catégories dans l'arbre.
    enum SortMode {
        /// Ordre alphabétique (insensible à la casse) à chaque niveau.
        case alphabetical
        /// Ordre de création (id croissant) à chaque niveau.
        case creation
    }

    /// Construit la forêt (liste de racines) depuis une liste plate de Category.
    static func buildForest(from flat: [Category], sort: SortMode = .alphabetical) -> [CategoryNode] {
        var nodeMap: [Int: CategoryNode] = [:]
        for cat in flat {
            nodeMap[cat.id] = CategoryNode(category: cat, children: [])
        }
        // Passe 1 : assigner tous les enfants dans nodeMap
        for cat in flat {
            guard let parentId = cat.parentId else { continue }
            let child = nodeMap[cat.id]!
            if var parent = nodeMap[parentId] {
                parent.children.append(child)
                nodeMap[parentId] = parent
            }
        }
        // Passe 2 : collecter les racines APRÈS que tous les enfants ont été assignés
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

    /// Retourne tous les IDs de la sous-arborescence (self + descendants).
    func allIds() -> [Int] {
        [category.id] + children.flatMap { $0.allIds() }
    }
}

struct Tag: Identifiable, Hashable {
    let id: Int
    var name: String
    var color: String?  // Hex sans # ex: "8B5CF6", nil = violet par défaut
}

/// Type d'un tier — permet d'adapter l'UI et le routage moteur.
enum TierType: String, Codable, CaseIterable, Identifiable {
    case merchant        // Commerce (Carrefour, Apple, etc.)
    case contact         // Personne physique (P2P, "Papa", "Marie")
    case `internal`      // Virement entre comptes propres
    case organization    // CAF, CPAM, employeur, école

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
    /// ID canonique côté NemorisEngine (ex: "carrefour"). Nil pour les tiers custom.
    var engineMerchantId: String? = nil
    /// Domaine web utilisé pour récupérer le favicon (AXE A). Nullable — résolu dynamiquement via le seed engine si vide.
    var domain: String? = nil
    // AXE C : champs d'édition complète exposés au user.
    var address: String? = nil
    var city: String? = nil
    /// Code pays ISO 3166-1 alpha-2 (ex "FR").
    var country: String? = nil
    var groupId: Int? = nil
    /// 1 = créé manuellement par l'utilisateur (pas de lien moteur attendu).
    var custom: Bool = false
    /// Note libre saisie par l'utilisateur.
    var note: String? = nil
    /// Type du tier (commerce / contact / interne / organisation) — v25.
    var tierType: TierType = .merchant
    /// Identifiant local CNContact (carnet de contacts iOS) si tier de type .contact
    /// et lié explicitement par l'user. Permet de récupérer la photo locale.
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
    /// Libellé brut bancaire (rempli à l'import, nil pour les transactions saisies manuellement).
    let libelleBrut: String?
    let amount: Double
    let date: Date
}

enum TransactionTypePicker: String, CaseIterable {
    case expense
    case income
}

/// État tri-state d'un tag dans un contexte de sélection multiple.
enum TagSelectionState {
    case all    // tous les éléments sélectionnés ont ce tag
    case some   // seulement certains éléments ont ce tag (indéterminé)
    case none   // aucun élément sélectionné n'a ce tag

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
    /// Libellé brut bancaire — lecture seule, non modifiable par l'utilisateur.
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

/// Statut d'un remboursement — v44 (AXE R).
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

/// Un remboursement attendu — rattaché à une transaction simple OU une entrée
/// Tricount (jamais les deux, CHECK XOR en base, v44 AXE R). Remplace
/// `transactions.reimbursement_payee_id` (0..1 payee) et `tricount_reimbursements`
/// (0..N payees).
struct Reimbursement: Identifiable {
    let id: Int
    let transactionId: Int?
    let tricountEntryId: Int?
    let payeeId: Int
    let payeeName: String
    var status: ReimbursementStatus
    let updatedAt: Date

    /// Montant signé dans la devise d'origine (négatif = dépense, le cas
    /// courant) — déjà signé par la requête : montant tel quel pour une
    /// transaction, part personnelle signée selon le type de l'entrée liée
    /// pour un remboursement Tricount.
    let amount: Double
    let currency: String
    /// Équivalent EUR signé (nil si conversion indisponible ou déjà en EUR).
    let eurAmount: Double?

    let originDescription: String
    let originDate: Date

    /// Catégorie de la transaction/entrée d'origine — nil si non catégorisée.
    /// Ajoutés en fin de liste avec valeurs par défaut pour ne pas casser les
    /// sites de construction existants qui n'ont pas cette info (remboursements
    /// Tricount seuls, par ex.).
    var categoryId: Int? = nil
    var categoryName: String = ""
    /// Payee PRINCIPAL de la transaction d'origine (ex. "Netflix") — distinct
    /// de `payeeName` qui est celui qui REMBOURSE. Vide côté Tricount (pas
    /// d'équivalent). Sert de repli d'affichage quand `originDescription` est
    /// vide (fréquent : c'est un champ de note libre, souvent jamais rempli).
    var originPayeeName: String = ""

    var isTricountOrigin: Bool { tricountEntryId != nil }
    var effectiveEurAmount: Double { eurAmount ?? amount }
    var isConverted: Bool { eurAmount != nil && currency != "EUR" && currency != "" }
    var needsConversion: Bool { currency != "EUR" && currency != "" && eurAmount == nil }
}

/// Remboursements groupés par catégorie de dépense d'origine — vue
/// complémentaire au groupement par payee dans `ReimbursementsSheet`.
struct CategoryReimbursementGroup: Identifiable {
    let categoryId: Int?
    let categoryName: String   // "Non catégorisé" si categoryId == nil
    let items: [Reimbursement]
    var id: Int { categoryId ?? -1 }
    var total: Double { items.reduce(0) { $0 + $1.effectiveEurAmount } }
    var transactionCount: Int { items.filter { !$0.isTricountOrigin }.count }
    var tricountCount: Int { items.filter { $0.isTricountOrigin }.count }
}

/// Remboursements groupés par payee — transactions simples et Tricount confondus.
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
    let parentCategory: String?   // nil si pas de catégorie parente
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
    var tiersSearchText: String = ""
    var categoryId: Int = -1
    var categoryName: String = ""
    var tagNames: [String] = []
    var tagFilteredTxIds: Set<Int>? = nil

    var hasActiveFilters: Bool {
        !tiersSearchText.isEmpty || categoryId != -1 || tagFilteredTxIds != nil
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
    /// Identifiant créé pour chaque ligne source (n° de ligne → id transaction).
    ///
    /// Nécessaire pour rattacher des données APRÈS l'insert — les métadonnées
    /// libres (v46) en particulier, qui référencent `transactions(id)`. Défaut
    /// vide pour que les sites d'appel qui n'en ont pas besoin restent
    /// inchangés.
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

/// Résumé des dépenses pour un tag (transactions + entrées Tricount)
struct TagExpenseSummary: Identifiable {
    let tag: Tag
    let transactionTotal: Double   // somme des montants de transactions
    let tricountTotal: Double      // somme des totaux d'entrées Tricount (en valeur absolue)
    var total: Double { transactionTotal + tricountTotal }
    var id: Int { tag.id }
}

/// Entrée Tricount taguée, pour l'affichage dans TagDetailView
struct TaggedTricountEntry: Identifiable {
    let id: Int
    let description: String
    let myShare: Double         // part de l'utilisateur dans la devise du groupe
    let currency: String        // devise du groupe (ex. "VND")
    let eurShare: Double?       // équivalent EUR de myShare (nil si taux inconnu)
    let date: Date
    let whoPaid: String
    let groupTitle: String
    let typeTransaction: String // "NORMAL", "INCOME", "BALANCE", "TRANSFER"

    /// Montant à utiliser pour les cumuls : EUR si disponible, sinon devise d'origine.
    var effectiveEurAmount: Double { eurShare ?? myShare }
    var isConverted: Bool { eurShare != nil && currency != "EUR" }
    /// Vrai si l'entrée est en devise étrangère SANS taux disponible → montant non convertible.
    var needsConversion: Bool { currency != "EUR" && currency != "" && eurShare == nil }
    /// Vrai si l'entrée est une dépense (NORMAL) → signe négatif dans les cumuls.
    var isExpense: Bool { typeTransaction.uppercased() == "NORMAL" }
    /// Montant signé pour les cumuls : négatif si dépense, positif si revenu/remboursement.
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
}

struct InvestmentAccount: Identifiable, Hashable {
    let id: Int
    var name: String
    var broker: String
    var currency: String
    var accountType: String
    var currentValue: Double       // Σ positions.current_value (dérivé)
    var investedAmount: Double     // Σ qty × PRU (dérivé)
    var openedAt: Date
    /// v34 — trésorerie disponible sur le compte (dividendes pas réinvestis,
    /// ventes en attente, dépôts récents). Persistée directement sur la row,
    /// éditable par l'user dans le form compte.
    var cashBalance: Double = 0

    /// Valorisation totale du compte = valeur des positions + trésorerie.
    /// C'est ce qu'on veut afficher comme "vrai" capital du compte.
    var totalValuation: Double { currentValue + cashBalance }
}

struct InvestmentPosition: Identifiable, Hashable {
    let id: Int
    let accountId: Int
    var assetType: String
    var assetName: String
    var ticker: String
    var isin: String = ""          // v31 : ISIN 12 chars (FR0000121329) — préféré pour sync via OpenFIGI
    var quantity: Double           // AXE K : DÉRIVÉE des ordres (Σ BUY - Σ SELL)
    var averageBuyPrice: Double    // AXE K : DÉRIVÉE des ordres (PRU pondéré des BUY)
    var currentValue: Double
    var purchaseDate: Date         // AXE K : date du PREMIER BUY chronologiquement

    var investedAmount: Double { quantity * averageBuyPrice }
    var pnl: Double { currentValue - investedAmount }

    /// Identifiant à privilégier pour la sync : ISIN > ticker. L'ISIN résout
    /// universellement vers le bon symbole tradable via OpenFIGI.
    var bestSyncIdentifier: String {
        !isin.isEmpty ? isin : ticker
    }

    /// True si la position est une crypto. Permet à la couche sync Yahoo de
    /// l'exclure (Yahoo cote des actions qui partagent les mêmes tickers que
    /// les cryptos : FET = action, BTC = ETF BlackRock, ETH = stock, etc.,
    /// ce qui corromprait les current_value obtenus via LiveSync/CoinGecko).
    var isCryptoAsset: Bool {
        assetType.uppercased() == "CRYPTO"
    }
}

// MARK: - AXE K : ordres d'investissement (multi-ordres par position)

/// Type d'un ordre. MVP : achat, vente, dividende. Splits/fusions hors scope.
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

/// Un ordre d'investissement = une opération sur une position à une date donnée.
/// Plusieurs ordres composent une position (qty et PRU sont dérivés à la volée).
struct InvestmentOrder: Identifiable, Hashable {
    let id: Int
    let positionId: Int
    var orderType: InvestmentOrderType
    var quantity: Double        // Toujours positive ; le signe est porté par orderType
    var unitPrice: Double       // Prix unitaire à l'exécution (devise du compte)
    var fees: Double            // Frais de courtage (0 si pas connus)
    var executedAt: Date
    var notes: String?
    /// AXE I Couche 1.5 : ID externe stable retourné par le provider (Binance tradeId,
    /// blockchain txHash). Permet la dédup entre syncs via UNIQUE INDEX SQL.
    /// nil pour les ordres saisis manuellement par l'user.
    var externalId: String? = nil

    /// Coût total brut (qty × prix + frais). Pour BUY = sortie cash, pour SELL = entrée cash.
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
    /// Cours d'OUVERTURE du pas de temps (la bougie : jour en `.daily`, tranche
    /// de 30 min en `.intraday30m`). C'est le « prix d'entrée » du point, que
    /// Yahoo et Stooq fournissent déjà à côté du close.
    ///
    /// Optionnel pour deux raisons :
    ///   - les séries déjà en cache disque n'ont pas la clé (le décodage Codable
    ///     synthétisé utilise `decodeIfPresent` pour un Optional → les caches
    ///     existants restent lisibles, sinon TOUT l'historique serait jeté au
    ///     premier décodage) ;
    ///   - CoinGecko `market_chart` ne renvoie que des prix ponctuels, pas d'OHLC.
    let open: Double?

    /// Init explicite : avec `open` en `let` sans valeur par défaut, l'init
    /// mémberwise synthétisé l'exigerait sur les ~6 sites de construction.
    init(id: String, identifier: String, date: Date, close: Double, open: Double? = nil) {
        self.id = id
        self.identifier = identifier
        self.date = date
        self.close = close
        self.open = open
    }
}
