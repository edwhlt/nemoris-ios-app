import Foundation

// MARK: - SearchService
//
// Recherche cross-modules : transactions, payees, comptes, catégories, tags,
// assets Patrimoine, prêts, biens immobiliers, goals.
//
// **Stratégie** : on charge les collections en mémoire (les repos ont des fetch
// rapides, < 50ms typique pour 5000 transactions) puis on filtre + score en Swift
// pur. Pas de FTS5 ni d'index inversé pour MVP — overkill pour la taille de DB
// d'une app finance personnelle (typiquement < 10k lignes par table).
//
// **Scoring** : 3 niveaux pour ordonner les résultats par pertinence :
//   - Exact match (case insensitive)        = 100
//   - StartsWith                            = 60
//   - Contains                              = 30
// Le score est ensuite agrégé par catégorie et la catégorie avec le meilleur
// top-score est listée en premier.
//
// **Limit** : 8 résultats par catégorie pour éviter de saturer la UI. Si l'user
// cherche un truc fréquent (ex : "loyer") il verra les 8 plus pertinents — les
// autres sont accessibles via les filtres natifs de chaque module.

enum SearchResult: Identifiable, Hashable {
    case transaction(FinanceTransaction)
    case payee(Tiers)
    case account(Account)
    case category(Category)
    case tag(Tag)
    case asset(PatrimoineAsset)
    case loan(PatrimoineLoan)
    case realEstate(PatrimoineRealEstate)
    case goal(Goal)

    var id: String {
        switch self {
        case .transaction(let t): return "tx_\(t.id)"
        case .payee(let p):       return "payee_\(p.id)"
        case .account(let a):     return "account_\(a.id)"
        case .category(let c):    return "category_\(c.id)"
        case .tag(let t):         return "tag_\(t.id)"
        case .asset(let a):       return "asset_\(a.id)"
        case .loan(let l):        return "loan_\(l.id)"
        case .realEstate(let r):  return "re_\(r.id)"
        case .goal(let g):        return "goal_\(g.id)"
        }
    }

    /// Catégorie utilisée pour grouper les résultats dans l'UI.
    var category: SearchCategory {
        switch self {
        case .transaction: return .transactions
        case .payee:       return .payees
        case .account:     return .accounts
        case .category:    return .categories
        case .tag:         return .tags
        case .asset, .loan, .realEstate: return .patrimoine
        case .goal:        return .goals
        }
    }
}

enum SearchCategory: String, CaseIterable, Identifiable {
    case transactions, payees, accounts, categories, tags, patrimoine, goals

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transactions: return "TRANSACTIONS"
        case .payees:       return "TIERS"
        case .accounts:     return "COMPTES"
        case .categories:   return "CATÉGORIES"
        case .tags:         return "TAGS"
        case .patrimoine:   return "PATRIMOINE"
        case .goals:        return "OBJECTIFS"
        }
    }

    var systemIcon: String {
        switch self {
        case .transactions: return "list.bullet.rectangle"
        case .payees:       return "person.crop.circle"
        case .accounts:     return "building.columns"
        case .categories:   return "tag.fill"
        case .tags:         return "number"
        case .patrimoine:   return "house.fill"
        case .goals:        return "target"
        }
    }
}

/// Volontairement PAS @MainActor : `search()` recharge toutes les collections
/// depuis SQLite — un travail de fond. Sur Mac, l'exécuter sur le main thread
/// pendant que le moteur de sync CloudKit écrit en concurrence gelait l'UI
/// (fix freezes 2026-07-17). Stateless : les repos sont des structs qui
/// ouvrent leur propre connexion par appel → Sendable sans état partagé.
struct SearchService: Sendable {

    static let shared = SearchService()

    private let txRepo: TransactionRepository
    private let patrimoineRepo: PatrimoineRepository
    private let goalRepo: GoalRepository

    /// `shared` reste le point d'accès de l'application ; la valeur par défaut
    /// vise sa base. Les tests instancient sur une base temporaire.
    init(store: SQLiteStore = SQLiteStore()) {
        txRepo = TransactionRepository(store: store)
        patrimoineRepo = PatrimoineRepository(store: store)
        goalRepo = GoalRepository(store: store)
    }

    /// Limite de résultats par catégorie. 8 est un bon compromis : assez pour ne
    /// pas frustrer, pas trop pour ne pas saturer le sheet sur petits écrans.
    private let limitPerCategory: Int = 8

    /// Lance la recherche et retourne les résultats groupés par catégorie + triés
    /// par score décroissant. Aucun side effect. Renvoie `[]` si query < 2 caractères
    /// (évite de tout matcher sur 1 lettre).
    func search(_ rawQuery: String) -> [SearchResult] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }

        var scored: [(SearchResult, Int)] = []

        // Transactions — on charge tout via fetchAllFilteredTransactions avec un
        // filter ouvert (pas génial pour très grosses bases mais OK MVP). Pour
        // limiter, on garde uniquement les matchs sur tiersName + information.
        let allTx = txRepo.fetchAllFilteredTransactions(
            filter: TransactionFilter(
                accountId: 0,  // 0 = "Tous les comptes" sentinel (cf. fetchAllFilteredTransactions)
                accountName: "",
                from: Date.distantPast,
                to: Date.distantFuture
            )
        )
        for tx in allTx {
            let score = max(
                scoreFor(field: tx.tiersName, query: q),
                scoreFor(field: tx.information, query: q)
            )
            if score > 0 {
                scored.append((.transaction(tx), score))
            }
        }

        // Payees / tiers
        for tier in txRepo.fetchTiers() {
            let score = scoreFor(field: tier.name, query: q)
            if score > 0 { scored.append((.payee(tier), score)) }
        }

        // Accounts
        for account in txRepo.fetchAccounts() {
            let score = scoreFor(field: account.name, query: q)
            if score > 0 { scored.append((.account(account), score)) }
        }

        // Categories
        for cat in txRepo.fetchCategories() {
            let score = scoreFor(field: cat.name, query: q)
            if score > 0 { scored.append((.category(cat), score)) }
        }

        // Tags
        for tag in txRepo.fetchAllTags() {
            let score = scoreFor(field: tag.name, query: q)
            if score > 0 { scored.append((.tag(tag), score)) }
        }

        // Patrimoine — assets
        for asset in patrimoineRepo.fetchAssets() {
            let score = scoreFor(field: asset.name, query: q)
            if score > 0 { scored.append((.asset(asset), score)) }
        }

        // Patrimoine — loans
        for loan in patrimoineRepo.fetchLoans() {
            let score = scoreFor(field: loan.name, query: q)
            if score > 0 { scored.append((.loan(loan), score)) }
        }

        // Patrimoine — real estate (nom + adresse)
        for re in patrimoineRepo.fetchRealEstate() {
            let nameScore = scoreFor(field: re.name, query: q)
            let addressScore = scoreFor(field: re.address ?? "", query: q)
            let score = max(nameScore, addressScore)
            if score > 0 { scored.append((.realEstate(re), score)) }
        }

        // Goals
        for goal in goalRepo.fetchGoals() {
            let score = scoreFor(field: goal.name, query: q)
            if score > 0 { scored.append((.goal(goal), score)) }
        }

        // Group by category, sort each group by score descending, limit, then flatten
        // with a stable order between categories (transactions first car le plus
        // fréquent, puis tiers, etc. — ordre du enum CaseIterable).
        var byCategory: [SearchCategory: [(SearchResult, Int)]] = [:]
        for item in scored {
            byCategory[item.0.category, default: []].append(item)
        }

        var ordered: [SearchResult] = []
        for cat in SearchCategory.allCases {
            guard let bucket = byCategory[cat] else { continue }
            let top = bucket.sorted { $0.1 > $1.1 }.prefix(limitPerCategory)
            ordered.append(contentsOf: top.map { $0.0 })
        }

        return ordered
    }

    /// Score 0…100. Plus c'est haut, plus c'est pertinent.
    private func scoreFor(field: String, query: String) -> Int {
        guard !field.isEmpty else { return 0 }
        let f = field.lowercased()
        if f == query              { return 100 }
        if f.hasPrefix(query)      { return 60 }
        if f.contains(query)       { return 30 }
        return 0
    }
}
