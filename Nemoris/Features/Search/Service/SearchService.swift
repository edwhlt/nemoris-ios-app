import Foundation

// MARK: - SearchService
//
// Cross-module search: transactions, payees, accounts, categories, tags,
// Patrimoine assets, loans, real-estate properties, goals, Investments
// accounts/positions, Budget envelopes/recurring items, Tricount groups/entries.
//
// **Strategy**: the collections are loaded into memory (the repos have fast
// fetches, < 50ms typical for 5000 transactions) then filtered + scored in pure
// Swift. No FTS5 or inverted index for the MVP — overkill for the database size
// of a personal-finance app (typically < 10k rows per table).
//
// **Scoring**: 3 levels to rank results by relevance:
//   - An exact match (case insensitive)    = 100
//   - StartsWith                            = 60
//   - Contains                              = 30
// The score is then aggregated per category, and the category with the best
// top-score is listed first.
//
// **Limit**: 8 results per category to avoid overwhelming the UI. If the user
// searches for something frequent (e.g. "rent") they'll see the 8 most relevant —
// the rest is reachable via each module's own filters.

enum SearchResult: Identifiable {
    case transaction(FinanceTransaction)
    case payee(Tiers)
    case account(Account)
    case category(Category)
    case tag(Tag)
    case asset(PatrimoineAsset)
    case loan(PatrimoineLoan)
    case realEstate(PatrimoineRealEstate)
    case goal(Goal)
    case investmentAccount(InvestmentAccount)
    case investmentPosition(InvestmentPosition)
    case budgetEnvelope(BudgetEnvelope)
    case recurringPattern(RecurringPattern)
    case tricountGroup(TricountGroup)
    case tricountEntry(TricountEntry)

    var id: String {
        switch self {
        case .transaction(let t):        return "tx_\(t.id)"
        case .payee(let p):              return "payee_\(p.id)"
        case .account(let a):            return "account_\(a.id)"
        case .category(let c):           return "category_\(c.id)"
        case .tag(let t):                return "tag_\(t.id)"
        case .asset(let a):              return "asset_\(a.id)"
        case .loan(let l):               return "loan_\(l.id)"
        case .realEstate(let r):         return "re_\(r.id)"
        case .goal(let g):               return "goal_\(g.id)"
        case .investmentAccount(let a):  return "invacc_\(a.id)"
        case .investmentPosition(let p): return "invpos_\(p.id)"
        case .budgetEnvelope(let e):     return "envelope_\(e.id)"
        case .recurringPattern(let p):   return "recurring_\(p.id)"
        case .tricountGroup(let g):      return "tcgroup_\(g.id)"
        case .tricountEntry(let e):      return "tcentry_\(e.id)"
        }
    }

    /// A category used to group results in the UI.
    var category: SearchCategory {
        switch self {
        case .transaction: return .transactions
        case .payee:       return .payees
        case .account:     return .accounts
        case .category:    return .categories
        case .tag:         return .tags
        case .asset, .loan, .realEstate: return .patrimoine
        case .goal:        return .goals
        case .investmentAccount, .investmentPosition: return .investments
        case .budgetEnvelope, .recurringPattern: return .budget
        case .tricountGroup, .tricountEntry: return .tricount
        }
    }
}

// ⚠️ MANUAL conformance, not synthesized: `TricountEntry` (and the other
// payloads) don't all need to be `Hashable` themselves — a search result's
// identity is its composite `id` (a prefix + the local id),
// not the model's whole value. An automatic synthesis would force
// EVERY present or future case to be `Hashable`, an unnecessary coupling.
extension SearchResult: Hashable {
    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum SearchCategory: String, CaseIterable, Identifiable {
    case transactions, payees, accounts, categories, tags, patrimoine, goals
    case investments, budget, tricount

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
        case .investments:  return "INVESTISSEMENTS"
        case .budget:       return "BUDGET"
        case .tricount:     return "TRICOUNT"
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
        case .investments:  return "chart.line.uptrend.xyaxis"
        case .budget:       return "chart.pie.fill"
        case .tricount:     return "person.2.fill"
        }
    }
}

/// Deliberately NOT @MainActor: `search()` reloads every collection
/// from SQLite — background work. On Mac, running it on the main thread
/// while the CloudKit sync engine wrote concurrently used to freeze the UI
/// (a fix from 2026-07-17). Stateless: the repos are structs that
/// open their own connection per call → Sendable with no shared state.
struct SearchService: Sendable {

    static let shared = SearchService()

    private let txRepo: TransactionRepository
    private let patrimoineRepo: PatrimoineRepository
    private let goalRepo: GoalRepository
    private let investmentRepo: InvestmentRepository
    private let budgetRepo: BudgetRepository
    private let tricountRepo: TricountRepository

    /// `shared` stays the app's access point; the default value
    /// targets its database. Tests instantiate against a temporary database.
    init(store: SQLiteStore = SQLiteStore()) {
        txRepo = TransactionRepository(store: store)
        patrimoineRepo = PatrimoineRepository(store: store)
        goalRepo = GoalRepository(store: store)
        investmentRepo = InvestmentRepository(store: store)
        budgetRepo = BudgetRepository(store: store)
        tricountRepo = TricountRepository(store: store)
    }

    /// The result limit per category. 8 is a good compromise: enough not
    /// to frustrate, not so much it overwhelms the sheet on small screens.
    private let limitPerCategory: Int = 8

    /// Runs the search and returns results grouped by category + sorted
    /// by decreasing score. No side effects. Returns `[]` if query < 2 characters
    /// (avoids matching everything on 1 letter).
    ///
    /// ⚠️ The 3 module flags are VALUE `Bool`s (not a direct read of
    /// `AppState`, which is `@MainActor` and not `Sendable`) — the caller
    /// captures them on the main thread and passes them here, run off the main thread
    /// (see the struct's docs). A disabled module ⇒ no query for its tables: consistent
    /// with the app treating it as "I don't use this feature", and it
    /// avoids surfacing a result toward a tab the user has
    /// deliberately hidden.
    func search(_ rawQuery: String,
                showInvestments: Bool = true,
                showBudget: Bool = true,
                showTricount: Bool = true) -> [SearchResult] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }

        var scored: [(SearchResult, Int)] = []

        // Transactions — everything is loaded via fetchAllFilteredTransactions with an
        // open filter (not great for very large databases but fine for the MVP). To
        // limit it, only matches on tiersName + information are kept.
        let allTx = txRepo.fetchAllFilteredTransactions(
            filter: TransactionFilter(
                accountId: 0,  // 0 = the "All accounts" sentinel (see fetchAllFilteredTransactions)
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

        // Investments — accounts + positions. No fetch-all-positions:
        // looping over accounts (typically < 20) like the rest of the app.
        if showInvestments {
            let accounts = investmentRepo.fetchAccounts()
            for account in accounts {
                let score = scoreFor(field: account.name, query: q)
                if score > 0 { scored.append((.investmentAccount(account), score)) }
            }
            for account in accounts {
                for position in investmentRepo.fetchPositions(accountId: account.id) {
                    let score = max(
                        scoreFor(field: position.assetName, query: q),
                        scoreFor(field: position.ticker, query: q)
                    )
                    if score > 0 { scored.append((.investmentPosition(position), score)) }
                }
            }
        }

        // Budget — envelopes + recurring patterns.
        if showBudget {
            for envelope in budgetRepo.fetchEnvelopes() {
                let score = scoreFor(field: envelope.name, query: q)
                if score > 0 { scored.append((.budgetEnvelope(envelope), score)) }
            }
            for pattern in budgetRepo.fetchPatterns() {
                let score = scoreFor(field: pattern.name, query: q)
                if score > 0 { scored.append((.recurringPattern(pattern), score)) }
            }
        }

        // Tricount — groups (title) + entries (description + who paid).
        if showTricount {
            let groups = tricountRepo.fetchGroups()
            for group in groups {
                let score = scoreFor(field: group.title, query: q)
                if score > 0 { scored.append((.tricountGroup(group), score)) }
            }
            for group in groups {
                for entry in tricountRepo.fetchEntries(groupId: group.id) {
                    let score = max(
                        scoreFor(field: entry.description, query: q),
                        scoreFor(field: entry.whoPaid, query: q)
                    )
                    if score > 0 { scored.append((.tricountEntry(entry), score)) }
                }
            }
        }

        // Group by category, sort each group by score descending, limit, then flatten
        // with a stable order between categories (transactions first, being the most
        // frequent, then payees, etc. — the CaseIterable enum's order).
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

    /// A score 0…100. The higher, the more relevant.
    private func scoreFor(field: String, query: String) -> Int {
        guard !field.isEmpty else { return 0 }
        let f = field.lowercased()
        if f == query              { return 100 }
        if f.hasPrefix(query)      { return 60 }
        if f.contains(query)       { return 30 }
        return 0
    }
}
