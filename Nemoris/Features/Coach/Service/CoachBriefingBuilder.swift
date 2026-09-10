import Foundation

// MARK: - CoachBriefingBuilder — le dossier « dépenses »
//
// Moteur PUR (`import Foundation` uniquement) : ni base, ni réseau, ni IA, ni
// SwiftUI. Doctrine `PortfolioEvolutionBuilder`.
//
// ─── Pourquoi un dossier, et pas les transactions brutes ───────────────────
//
// Six mois d'historique, c'est couramment 1 000 à 5 000 transactions. Les
// envoyer telles quelles représente 100 000+ tokens : impossible sur
// Foundation Models (~4 000 de contexte), lent et coûteux ailleurs. Un coach
// qui « interprète toutes les transactions » ne peut donc pas les LIRE toutes.
//
// On lui présente à la place un DOSSIER : les mêmes faits, agrégés et
// ordonnés, en ~3 000 caractères. C'est le travail qu'un consultant humain
// ferait avant de rendre un avis — il ne lit pas les 5 000 lignes, il regarde
// les moyennes, les tendances, les concentrations et les anomalies.
//
// ⚠️ Le dossier est BORNÉ (`maxCharacters`). Sans plafond, un utilisateur avec
// 200 catégories ou 900 marchands ferait exploser le contexte et le modèle
// tronquerait EN SILENCE — en perdant justement la fin du dossier, là où se
// trouvent les objectifs de l'utilisateur.

enum CoachBriefingBuilder {

    // MARK: - Entrée

    struct Input {
        var transactions: [FinanceTransaction]
        var categories: [Category]
        var tiers: [Tiers]
        var patterns: [RecurringPattern]
        var envelopes: [BudgetEnvelope]
        /// Signaux déjà repérés par la détection statistique
        /// (`InsightEngine`), en une ligne chacun. Ils ne remplacent pas
        /// l'analyse du modèle : ils lui évitent de re-déduire ce qu'un
        /// calcul déterministe sait déjà, et lui donnent des points d'entrée.
        var signals: [String]
        var objectives: String
        var now: Date

        init(transactions: [FinanceTransaction], categories: [Category], tiers: [Tiers],
             patterns: [RecurringPattern], envelopes: [BudgetEnvelope],
             signals: [String], objectives: String, now: Date = Date()) {
            self.transactions = transactions
            self.categories = categories
            self.tiers = tiers
            self.patterns = patterns
            self.envelopes = envelopes
            self.signals = signals
            self.objectives = objectives
            self.now = now
        }
    }

    // MARK: - Réglages

    /// Plafonds de listes. Calibrés pour tenir dans `maxCharacters` sans
    /// perdre le signal : au-delà du 12ᵉ poste de dépense ou du 15ᵉ marchand,
    /// les montants deviennent anecdotiques face aux premiers.
    static let maxCategories = 12
    static let maxMerchants = 15
    static let maxRecurring = 20
    static let maxSignals = 8
    /// ⚠️ Ces deux plafonds manquaient : le détail mensuel et les enveloppes
    /// étaient les seules listes non bornées du dossier. Sur un historique
    /// long ou un budget très découpé, elles poussaient le dossier au-delà de
    /// `maxCharacters` — et c'est alors la TRONCATURE qui décidait de ce qui
    /// partait au modèle, en coupant la fin. Un plafond explicite garde la
    /// main sur ce qu'on sacrifie.
    static let maxMonths = 24
    static let maxEnvelopes = 20
    /// Borne dure du dossier en mode `.compact` : ~6 000 caractères ≈ 1 600 tokens.
    ///
    /// ⚠️ Ce n'est PAS une marge confortable sur un modèle à 4 000 tokens de
    /// contexte : avec ~700 tokens de consignes, il reste ~1 700 tokens pour
    /// la réponse. C'est jouable, mais c'est précisément ce qui peut faire
    /// COUPER la réponse en plein JSON sur un dossier maximal — d'où le repli
    /// de récupération dans `CoachResponseParser` (retour d'usage 2026-08-28).
    static let maxCharacters = 6_000
    /// Borne du dossier en mode `.generous` (serveur local / cloud) : le
    /// contexte de ces backends encaisse largement un dossier 3-4× plus riche
    /// — pour la plupart des utilisateurs, le dossier ne l'atteint même pas
    /// (les plafonds de LISTE ci-dessus, eux, ne bougent pas : au-delà du 12ᵉ
    /// poste ou du 24ᵉ mois, le signal devient anecdotique quel que soit le
    /// modèle qui le lit — cf. commentaire des plafonds de liste).
    static let maxCharactersGenerous = 20_000

    // MARK: - Construction

    /// Le dossier découpé en blocs NOMMÉS.
    ///
    /// C'est la même matière que `build`, mais adressable : sur une fenêtre de
    /// contexte étroite, `CoachPassPlanner` répartit ces sections entre
    /// plusieurs appels au lieu de tout envoyer d'un coup (et de se faire
    /// tronquer là où le hasard décide).
    static func sections(_ input: Input) -> [CoachBriefingSection] {
        var out: [CoachBriefingSection] = [
            CoachBriefingSection(id: "profil", title: "Profil et flux mensuels", body: profileBlock(input)),
            CoachBriefingSection(id: "categories", title: "Dépenses par catégorie", body: categoryBlock(input)),
        ]
        if let recurring = recurringBlock(input) {
            out.append(CoachBriefingSection(id: "recurrents", title: "Charges récurrentes", body: recurring))
        }
        if let merchants = merchantBlock(input) {
            out.append(CoachBriefingSection(id: "marchands", title: "Principaux marchands", body: merchants))
        }
        if let envelopes = envelopeBlock(input) {
            out.append(CoachBriefingSection(id: "enveloppes", title: "Enveloppes budgétaires", body: envelopes))
        }
        if let signals = signalBlock(input) {
            out.append(CoachBriefingSection(id: "signaux", title: "Signaux repérés automatiquement", body: signals))
        }
        return out
    }

    /// Les chiffres clés en quelques lignes, RÉPÉTÉS dans chaque passe d'une
    /// analyse découpée.
    ///
    /// ⚠️ Sans eux, une passe qui ne voit que « les marchands » n'a aucune
    /// idée du niveau de revenu et recommande dans le vide (« réduis Grab »
    /// sans savoir si 417 € pèsent quelque chose). Le coût — ~250 caractères
    /// par passe — est le prix de la pertinence.
    static func condensedHeader(_ input: Input) -> String {
        let months = monthlyTotals(input)
        guard !months.isEmpty else { return "CHIFFRES CLÉS\nAucune transaction sur la période analysée." }
        let avgIncome = months.map(\.income).reduce(0, +) / Double(months.count)
        let avgExpense = months.map(\.expense).reduce(0, +) / Double(months.count)
        let savings = avgIncome - avgExpense
        let rate = avgIncome > 0 ? savings / avgIncome * 100 : 0
        return """
        CHIFFRES CLÉS (\(months.count) mois : \(months.first?.label ?? "?") → \(months.last?.label ?? "?"))
        Revenus moyens : \(money(avgIncome))/mois · Dépenses moyennes : \(money(avgExpense))/mois
        Épargne moyenne : \(money(savings))/mois, soit \(percent(rate)) du revenu
        """
    }

    static func build(_ input: Input, budget: CoachContextBudget = .compact) -> String {
        var text = sections(input).map(\.body).joined(separator: "\n\n")
        let limit = budget == .compact ? maxCharacters : maxCharactersGenerous
        // Les objectifs sont ajoutés APRÈS la troncature du reste : ils sont
        // ce que l'utilisateur a écrit lui-même, ils ne doivent jamais être
        // la partie sacrifiée quand le dossier est trop long.
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n[…dossier tronqué]"
        }
        if let objectives = objectivesBlock(input) {
            text += "\n\n" + objectives
        }
        return text
    }

    // MARK: - Profil

    private static func profileBlock(_ input: Input) -> String {
        let months = monthlyTotals(input)
        guard !months.isEmpty else {
            return "PROFIL\nAucune transaction sur la période analysée."
        }
        let incomes = months.map(\.income)
        let expenses = months.map(\.expense)
        let avgIncome = incomes.reduce(0, +) / Double(months.count)
        let avgExpense = expenses.reduce(0, +) / Double(months.count)
        let savings = avgIncome - avgExpense
        let rate = avgIncome > 0 ? savings / avgIncome * 100 : 0

        // Le taux d'épargne mois par mois : une moyenne de 12 % peut cacher
        // « +30 % puis -6 % », ce qui n'appelle pas du tout le même conseil.
        let monthlyRates = months.map { $0.income > 0 ? ($0.income - $0.expense) / $0.income * 100 : 0 }
        let minRate = monthlyRates.min() ?? 0
        let maxRate = monthlyRates.max() ?? 0

        var lines = ["PROFIL"]
        lines.append("Période analysée : \(months.count) mois (\(months.first?.label ?? "?") → \(months.last?.label ?? "?"))")
        lines.append("Transactions : \(input.transactions.count)")
        lines.append("Revenus moyens : \(money(avgIncome))/mois")
        lines.append("Dépenses moyennes : \(money(avgExpense))/mois")
        lines.append("Épargne moyenne : \(money(savings))/mois, soit \(percent(rate)) du revenu")
        lines.append("Taux d'épargne mensuel — le plus bas \(percent(minRate)), le plus haut \(percent(maxRate))")
        lines.append("")
        lines.append("Détail mensuel (revenus / dépenses / solde) :")
        // Les mois les plus RÉCENTS : c'est la situation actuelle qui appelle
        // un conseil, pas celle d'il y a trois ans.
        for m in months.suffix(maxMonths) {
            lines.append("  \(m.label) : \(money(m.income)) / \(money(m.expense)) / \(money(m.income - m.expense))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Catégories

    private static func categoryBlock(_ input: Input) -> String {
        let cal = calendar
        guard let midpoint = cal.date(byAdding: .month, value: -3, to: input.now) else {
            return "DÉPENSES PAR CATÉGORIE\n(indisponible)"
        }
        let parentOf = parentIndex(input.categories)
        let nameOf = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0.name) })

        var total: [Int: Double] = [:]      // sur toute la période
        var recent: [Int: Double] = [:]     // 3 derniers mois
        var previous: [Int: Double] = [:]   // les 3 d'avant
        var uncategorized: Double = 0

        for tx in input.transactions where tx.amount < 0 {
            let amount = abs(tx.amount)
            guard let cid = tx.categoryId else { uncategorized += amount; continue }
            let root = rootCategory(cid, parentOf: parentOf)
            total[root, default: 0] += amount
            if tx.date >= midpoint { recent[root, default: 0] += amount }
            else { previous[root, default: 0] += amount }
        }

        let grandTotal = total.values.reduce(0, +) + uncategorized
        guard grandTotal > 0 else { return "DÉPENSES PAR CATÉGORIE\nAucune dépense sur la période." }

        let monthCount = max(1, monthlyTotals(input).count)
        var lines = ["DÉPENSES PAR CATÉGORIE (moyenne mensuelle · part du total · tendance 3 derniers mois vs 3 précédents)"]
        for (cid, amount) in total.sorted(by: { $0.value > $1.value }).prefix(maxCategories) {
            let name = nameOf[cid] ?? "Catégorie \(cid)"
            let monthly = amount / Double(monthCount)
            let share = amount / grandTotal * 100
            lines.append("  \(name) : \(money(monthly))/mois · \(percent(share)) · \(trendLabel(recent: recent[cid] ?? 0, previous: previous[cid] ?? 0))")
        }
        if uncategorized > 0 {
            let share = uncategorized / grandTotal * 100
            lines.append("  NON CATÉGORISÉ : \(money(uncategorized / Double(monthCount)))/mois · \(percent(share))")
        }
        return lines.joined(separator: "\n")
    }

    /// Tendance en clair plutôt qu'en pourcentage brut : « +18 % » sur une
    /// base de 4 € n'a aucun sens, et le modèle ne peut pas le savoir sans la
    /// base. On ne qualifie donc que ce qui est significatif en montant.
    private static func trendLabel(recent: Double, previous: Double) -> String {
        guard previous > 30 || recent > 30 else { return "volume faible" }
        guard previous > 0 else { return "nouveau poste" }
        let delta = (recent - previous) / previous * 100
        if delta > 15 { return "en hausse de \(percent(delta))" }
        if delta < -15 { return "en baisse de \(percent(abs(delta)))" }
        return "stable"
    }

    // MARK: - Charges récurrentes

    private static func recurringBlock(_ input: Input) -> String? {
        let expenses = input.patterns.filter { $0.isActive && $0.isExpense }
        guard !expenses.isEmpty else { return nil }
        let monthlyTotal = expenses.reduce(0.0) { $0 + monthlyEquivalent($1) }
        var lines = ["CHARGES RÉCURRENTES SUIVIES (\(expenses.count), soit \(money(monthlyTotal))/mois au total)"]
        for p in expenses.sorted(by: { monthlyEquivalent($0) > monthlyEquivalent($1) }).prefix(maxRecurring) {
            lines.append("  \(p.name) : \(money(p.displayAmount)) \(p.frequency.label.lowercased()) (\(money(monthlyEquivalent(p)))/mois)")
        }
        return lines.joined(separator: "\n")
    }

    private static func monthlyEquivalent(_ p: RecurringPattern) -> Double {
        let amount = abs(p.amountAvg)
        switch p.frequency {
        case .daily:      return amount * 30.42
        case .weekly:     return amount * 4.33
        case .biweekly:   return amount * 2.17
        case .monthly:    return amount
        case .quarterly:  return amount / 3
        case .semiannual: return amount / 6
        case .yearly:     return amount / 12
        }
    }

    // MARK: - Marchands

    private static func merchantBlock(_ input: Input) -> String? {
        var byTier: [Int: (count: Int, total: Double)] = [:]
        for tx in input.transactions where tx.amount < 0 {
            guard let tid = tx.tiersId else { continue }
            var entry = byTier[tid] ?? (0, 0)
            entry.count += 1
            entry.total += abs(tx.amount)
            byTier[tid] = entry
        }
        guard !byTier.isEmpty else { return nil }
        let nameOf = Dictionary(uniqueKeysWithValues: input.tiers.map { ($0.id, $0.name) })
        var lines = ["PRINCIPAUX MARCHANDS SUR LA PÉRIODE (nombre d'achats · total · panier moyen)"]
        for (tid, entry) in byTier.sorted(by: { $0.value.total > $1.value.total }).prefix(maxMerchants) {
            let name = nameOf[tid] ?? "Tiers \(tid)"
            let avg = entry.total / Double(max(1, entry.count))
            lines.append("  \(name) : \(entry.count) achats · \(money(entry.total)) · \(money(avg)) en moyenne")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Enveloppes

    private static func envelopeBlock(_ input: Input) -> String? {
        let active = input.envelopes.filter { $0.isActive }
        guard !active.isEmpty else { return nil }
        let progresses = EnvelopeSpendingCalculator.progresses(
            envelopes: active,
            transactions: currentMonthTransactions(input),
            categories: input.categories
        )
        guard !progresses.isEmpty else { return nil }
        var lines = ["ENVELOPPES BUDGÉTAIRES DU MOIS EN COURS (alloué · dépensé · état)"]
        // Triées par tension décroissante, donc le plafond coupe les
        // enveloppes les plus confortables — celles sur lesquelles il n'y a
        // justement rien à dire.
        for p in progresses.sorted(by: { $0.rawRatio > $1.rawRatio }).prefix(maxEnvelopes) {
            let state: String
            switch p.healthState {
            case .exceeded: state = "DÉPASSÉE"
            case .warning:  state = "proche de la limite"
            case .healthy:  state = "dans le budget"
            }
            lines.append("  \(p.envelope.name) : \(money(p.allocated)) · \(money(p.spent)) · \(state)")
        }
        return lines.joined(separator: "\n")
    }

    private static func currentMonthTransactions(_ input: Input) -> [FinanceTransaction] {
        let cal = calendar
        let comps = cal.dateComponents([.year, .month], from: input.now)
        guard let start = cal.date(from: comps) else { return [] }
        return input.transactions.filter { $0.date >= start && $0.date <= input.now }
    }

    // MARK: - Signaux & objectifs

    private static func signalBlock(_ input: Input) -> String? {
        let signals = input.signals.filter { !$0.isEmpty }
        guard !signals.isEmpty else { return nil }
        var lines = ["SIGNAUX REPÉRÉS AUTOMATIQUEMENT (détection statistique — à confirmer ou nuancer)"]
        for s in signals.prefix(maxSignals) { lines.append("  - \(s)") }
        return lines.joined(separator: "\n")
    }

    /// Interne (pas privé) : le découpage en passes le répète dans CHAQUE
    /// passe — les objectifs sont la priorité n°1 du coach, une passe qui ne
    /// les verrait pas conseillerait à côté.
    static func objectivesBlock(_ input: Input) -> String? {
        let trimmed = input.objectives.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Borné aussi : un utilisateur peut coller trois pages.
        let capped = trimmed.count > 1_500 ? String(trimmed.prefix(1_500)) + "…" : trimmed
        return "OBJECTIFS ÉCRITS PAR L'UTILISATEUR (à prendre comme la priorité n°1)\n\(capped)"
    }

    // MARK: - Agrégation mensuelle

    struct MonthTotals {
        let label: String
        let income: Double
        let expense: Double
    }

    /// Totaux par mois calendaire, ordre chronologique.
    static func monthlyTotals(_ input: Input) -> [MonthTotals] {
        let cal = calendar
        var buckets: [DateComponents: (income: Double, expense: Double)] = [:]
        for tx in input.transactions {
            let comps = cal.dateComponents([.year, .month], from: tx.date)
            var entry = buckets[comps] ?? (0, 0)
            if tx.amount >= 0 { entry.income += tx.amount } else { entry.expense += abs(tx.amount) }
            buckets[comps] = entry
        }
        return buckets
            .sorted { ($0.key.year ?? 0, $0.key.month ?? 0) < ($1.key.year ?? 0, $1.key.month ?? 0) }
            .map { key, value in
                MonthTotals(label: String(format: "%04d-%02d", key.year ?? 0, key.month ?? 0),
                            income: value.income, expense: value.expense)
            }
    }

    // MARK: - Helpers

    /// Calendrier grégorien explicite : un moteur pur ne doit pas dépendre du
    /// réglage régional de l'appareil pour découper des mois.
    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// Remonte la chaîne de parenté jusqu'à la catégorie racine. Agréger au
    /// niveau racine évite un dossier saturé de sous-catégories à 4 € qui
    /// noieraient les vrais postes.
    private static func rootCategory(_ id: Int, parentOf: [Int: Int]) -> Int {
        var current = id
        // Borne de sécurité : une hiérarchie corrompue (cycle) ne doit pas
        // faire tourner le moteur à l'infini.
        for _ in 0..<10 {
            guard let parent = parentOf[current] else { return current }
            current = parent
        }
        return current
    }

    private static func parentIndex(_ categories: [Category]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for c in categories { if let p = c.parentId { result[c.id] = p } }
        return result
    }

    /// ⚠️ Locale forcée : moteur pur, sans accès à l'environnement SwiftUI.
    /// Même convention que `InsightEngine` / `AlertEngine` (cf. CLAUDE.md §5).
    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").presentation(.narrow).locale(Locale(identifier: "fr_FR")))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value)
    }
}
