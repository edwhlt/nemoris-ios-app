import Foundation

// MARK: - InvestmentBriefingBuilder — le dossier « portefeuille »
//
// Moteur PUR, même doctrine et mêmes raisons que `CoachBriefingBuilder` :
// on ne peut pas envoyer l'historique complet des ordres et des cours à un
// modèle, on lui présente le dossier qu'un conseiller lirait.
//
// ⚠️ Ce dossier ne contient QUE des faits mesurés dans la base. Aucune donnée
// de marché externe, aucune projection : le modèle doit raisonner sur la
// situation réelle de l'utilisateur (concentration, frais, liquidités
// dormantes, cohérence avec ses objectifs), pas prédire des cours.

enum InvestmentBriefingBuilder {

    // MARK: - Entrée

    struct Input {
        var accounts: [InvestmentAccount]
        var positions: [InvestmentPosition]
        /// Ordres récents, pour caractériser l'activité (buy & hold vs
        /// trading actif) — deux profils qui n'appellent pas les mêmes conseils.
        var recentOrders: [InvestmentOrder]
        var objectives: String
        var now: Date

        init(accounts: [InvestmentAccount], positions: [InvestmentPosition],
             recentOrders: [InvestmentOrder], objectives: String, now: Date = Date()) {
            self.accounts = accounts
            self.positions = positions
            self.recentOrders = recentOrders
            self.objectives = objectives
            self.now = now
        }
    }

    static let maxPositions = 20
    /// Borne dure du dossier en mode `.compact` (Apple Intelligence). Voir
    /// `CoachBriefingBuilder.maxCharacters` pour le détail du calcul.
    static let maxCharacters = 6_000
    /// Borne du dossier en mode `.generous` (serveur local / cloud) — même
    /// raisonnement que `CoachBriefingBuilder.maxCharactersGenerous`.
    static let maxCharactersGenerous = 20_000

    // MARK: - Construction

    /// Le dossier découpé en blocs NOMMÉS — même rôle que
    /// `CoachBriefingBuilder.sections` : rendre le dossier distribuable entre
    /// plusieurs passes quand la fenêtre de contexte est étroite.
    static func sections(_ input: Input) -> [CoachBriefingSection] {
        var out: [CoachBriefingSection] = [
            CoachBriefingSection(id: "portefeuille", title: "Vue d'ensemble du portefeuille", body: overviewBlock(input))
        ]
        if let accounts = accountBlock(input) {
            out.append(CoachBriefingSection(id: "comptes", title: "Comptes", body: accounts))
        }
        if let allocation = allocationBlock(input) {
            out.append(CoachBriefingSection(id: "allocation", title: "Allocation et concentration", body: allocation))
        }
        if let positions = positionBlock(input) {
            out.append(CoachBriefingSection(id: "positions", title: "Positions", body: positions))
        }
        if let activity = activityBlock(input) {
            out.append(CoachBriefingSection(id: "activite", title: "Activité récente", body: activity))
        }
        return out
    }

    /// Les chiffres clés, répétés dans chaque passe d'une analyse découpée
    /// (cf. `CoachBriefingBuilder.condensedHeader`).
    static func condensedHeader(_ input: Input) -> String {
        let invested = input.positions.reduce(0.0) { $0 + $1.investedAmount }
        let current = input.positions.reduce(0.0) { $0 + $1.currentValue }
        let cash = input.accounts.reduce(0.0) { $0 + $1.cashBalance }
        let pnl = current - invested
        let pnlPct = invested > 0 ? pnl / invested * 100 : 0
        return """
        CHIFFRES CLÉS
        Valorisation : \(money(current)) · Investi : \(money(invested)) · P&L latent : \(money(pnl)) (\(signedPercent(pnlPct)))
        Liquidités non investies : \(money(cash)) · \(input.positions.count) positions sur \(input.accounts.count) comptes
        """
    }

    static func build(_ input: Input, budget: CoachContextBudget = .compact) -> String {
        var text = sections(input).map(\.body).joined(separator: "\n\n")
        let limit = budget == .compact ? maxCharacters : maxCharactersGenerous
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n[…dossier tronqué]"
        }
        if let objectives = objectivesBlock(input) {
            text += "\n\n" + objectives
        }
        return text
    }

    // MARK: - Vue d'ensemble

    private static func overviewBlock(_ input: Input) -> String {
        let invested = input.positions.reduce(0.0) { $0 + $1.investedAmount }
        let current = input.positions.reduce(0.0) { $0 + $1.currentValue }
        let cash = input.accounts.reduce(0.0) { $0 + $1.cashBalance }
        let pnl = current - invested
        let pnlPct = invested > 0 ? pnl / invested * 100 : 0
        let totalCapital = current + cash

        var lines = ["PORTEFEUILLE"]
        lines.append("Valorisation des positions : \(money(current))")
        lines.append("Montant investi (PRU × quantité) : \(money(invested))")
        lines.append("Plus/moins-value latente : \(money(pnl)) (\(signedPercent(pnlPct)))")
        lines.append("Liquidités non investies : \(money(cash))")
        if totalCapital > 0 {
            // Les liquidités dormantes sont un signal de coaching de premier
            // ordre : du capital immobilisé sans rendement, souvent par
            // inertie plutôt que par choix.
            lines.append("Capital total : \(money(totalCapital)) — dont \(percent(cash / totalCapital * 100)) en liquidités")
        }
        lines.append("Nombre de positions : \(input.positions.count) · Nombre de comptes : \(input.accounts.count)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Comptes

    private static func accountBlock(_ input: Input) -> String? {
        guard !input.accounts.isEmpty else { return nil }
        let total = input.accounts.reduce(0.0) { $0 + $1.totalValuation }
        guard total > 0 else { return nil }
        var lines = ["COMPTES (valorisation · part · liquidités)"]
        for a in input.accounts.sorted(by: { $0.totalValuation > $1.totalValuation }) {
            let share = a.totalValuation / total * 100
            let type = a.accountType.isEmpty ? "" : " [\(a.accountType)]"
            lines.append("  \(a.name)\(type) : \(money(a.totalValuation)) · \(percent(share)) · liquidités \(money(a.cashBalance))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Allocation & concentration

    private static func allocationBlock(_ input: Input) -> String? {
        let total = input.positions.reduce(0.0) { $0 + $1.currentValue }
        guard total > 0 else { return nil }

        var byType: [String: Double] = [:]
        for p in input.positions {
            let key = p.assetType.isEmpty ? "non typé" : p.assetType
            byType[key, default: 0] += p.currentValue
        }

        var lines = ["ALLOCATION ET CONCENTRATION"]
        for (type, value) in byType.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(type) : \(money(value)) · \(percent(value / total * 100))")
        }

        // La concentration est LE risque structurel qu'un particulier ne voit
        // pas de lui-même : il regarde ses lignes une par une, jamais leur
        // poids relatif.
        let sorted = input.positions.map(\.currentValue).sorted(by: >)
        let top1 = sorted.first ?? 0
        let top3 = sorted.prefix(3).reduce(0, +)
        lines.append("  Poids de la 1re ligne : \(percent(top1 / total * 100)) · des 3 premières : \(percent(top3 / total * 100))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Positions

    private static func positionBlock(_ input: Input) -> String? {
        guard !input.positions.isEmpty else { return nil }
        let total = input.positions.reduce(0.0) { $0 + $1.currentValue }
        guard total > 0 else { return nil }
        let accountName = Dictionary(uniqueKeysWithValues: input.accounts.map { ($0.id, $0.name) })

        var lines = ["POSITIONS (valorisation · poids · PRU vs cours actuel · P&L)"]
        for p in input.positions.sorted(by: { $0.currentValue > $1.currentValue }).prefix(maxPositions) {
            let share = p.currentValue / total * 100
            let unitPrice = p.quantity > 0 ? p.currentValue / p.quantity : 0
            let pnlPct = p.investedAmount > 0 ? p.pnl / p.investedAmount * 100 : 0
            let label = p.ticker.isEmpty ? p.assetName : "\(p.ticker) (\(p.assetName))"
            let account = accountName[p.accountId].map { " · \($0)" } ?? ""
            lines.append("  \(label) : \(money(p.currentValue)) · \(percent(share)) · PRU \(money(p.averageBuyPrice)) vs \(money(unitPrice)) · \(signedPercent(pnlPct))\(account)")
        }
        if input.positions.count > maxPositions {
            lines.append("  (… \(input.positions.count - maxPositions) autres lignes de poids inférieur)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Activité

    private static func activityBlock(_ input: Input) -> String? {
        guard !input.recentOrders.isEmpty else { return nil }
        var buys = 0, sells = 0, dividends = 0
        var dividendTotal = 0.0
        var feesTotal = 0.0
        for o in input.recentOrders {
            feesTotal += o.fees
            switch o.orderType {
            case .buy:  buys += 1
            case .sell: sells += 1
            case .dividend:
                dividends += 1
                dividendTotal += o.quantity * o.unitPrice
            }
        }
        var lines = ["ACTIVITÉ RÉCENTE"]
        lines.append("  \(buys) achats · \(sells) ventes · \(dividends) dividendes (\(money(dividendTotal)) perçus)")
        // Les frais cumulés sont un levier concret et chiffrable, que
        // l'utilisateur ne totalise jamais lui-même.
        if feesTotal > 0 {
            lines.append("  Frais de courtage cumulés sur la période : \(money(feesTotal))")
        }
        return lines.joined(separator: "\n")
    }

    /// Interne (pas privé) : répété dans chaque passe d'une analyse découpée,
    /// même raison que côté dépenses.
    static func objectivesBlock(_ input: Input) -> String? {
        let trimmed = input.objectives.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = trimmed.count > 1_500 ? String(trimmed.prefix(1_500)) + "…" : trimmed
        return "OBJECTIFS ÉCRITS PAR L'UTILISATEUR (à prendre comme la priorité n°1)\n\(capped)"
    }

    // MARK: - Helpers

    /// ⚠️ Locale forcée : moteur pur, sans accès à l'environnement SwiftUI
    /// (cf. CLAUDE.md §5).
    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").presentation(.narrow).locale(Locale(identifier: "fr_FR")))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value)
    }

    private static func signedPercent(_ value: Double) -> String {
        String(format: "%+.1f %%", value)
    }
}
