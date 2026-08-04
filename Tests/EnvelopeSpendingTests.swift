import Foundation

// Tests unitaires d'EnvelopeSpendingCalculator — compile les fichiers RÉELS
// (BudgetModels + EnvelopeSpendingCalculator) avec des stubs minimaux.
//
// Régression principale verrouillée ici : les QUATRE implémentations divergentes
// du "dépensé par enveloppe" qui coexistaient avant la factorisation. Elles
// produisaient des contradictions visibles à l'écran (une enveloppe "dépassée"
// dans l'AlertsBanner et "saine" dans le bandeau Budget, sur le même Dashboard) :
//
//   • AnnualDashboardViewModel : sous-catégories OUI, enveloppes annuelles NON
//   • BudgetViewModel          : sous-catégories OUI, enveloppes annuelles OUI
//   • AlertEngine              : sous-catégories NON, enveloppes annuelles NON
//   • WidgetDataStore          : sous-catégories NON, enveloppes annuelles OUI
//
// t1 et t2 verrouillent les deux règles qui divergeaient.

// MARK: - Stubs des types de l'app

struct FinanceTransaction: Identifiable, Hashable {
    let id: Int
    let categoryId: Int?
    let amount: Double
    let date: Date
}

struct Category: Identifiable, Hashable {
    let id: Int
    var name: String
    var parentId: Int? = nil
    var icon: String? = nil
    var displayIcon: String { icon ?? "tag.fill" }
}

// MARK: - Harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func expectEqual(_ lhs: Double, _ rhs: Double, _ label: String) {
    expect(abs(lhs - rhs) < 0.005, label, "attendu \(rhs), obtenu \(lhs)")
}

let now = Date()

// Référentiel : "Alimentation" (10) avec deux enfants, "Loisirs" (20) sans enfant.
let categories: [Category] = [
    Category(id: 10, name: "Alimentation"),
    Category(id: 11, name: "Supermarché", parentId: 10),
    Category(id: 12, name: "Restaurant", parentId: 10),
    Category(id: 20, name: "Loisirs"),
]

func envelope(_ id: Int, category: Int?, amount: Double, period: BudgetPeriod = .monthly) -> BudgetEnvelope {
    BudgetEnvelope(id: id, name: "Env\(id)", categoryId: category, amount: amount,
                   period: period, startDate: now, isActive: true)
}

func expense(_ id: Int, category: Int?, _ amount: Double) -> FinanceTransaction {
    FinanceTransaction(id: id, categoryId: category, amount: -abs(amount), date: now)
}

@main
enum EnvelopeSpendingTests {
    static func main() {

// MARK: - t1 · Hiérarchie des catégories

print("\nt1 · Une dépense sur une sous-catégorie compte dans l'enveloppe parente")
do {
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 10, amount: 400)],
        transactions: [
            expense(1, category: 11, 120),   // Supermarché → enfant
            expense(2, category: 12, 80),    // Restaurant  → enfant
            expense(3, category: 10, 50),    // Alimentation → la catégorie elle-même
            expense(4, category: 20, 999),   // Loisirs → ne doit PAS compter
        ],
        categories: categories
    )
    expectEqual(progresses[0].spent, 250, "les enfants sont agrégés dans la parente")
    expect(progresses[0].healthState == .healthy, "250 / 400 = 62 % → healthy")
    expectEqual(progresses[0].allocated, 400, "enveloppe mensuelle : allocated = amount")
}

// MARK: - t2 · Enveloppe annuelle mensualisée

print("\nt2 · Une enveloppe annuelle est mensualisée (sinon jamais dépassée)")
do {
    // 1200 €/an = 100 €/mois. 150 € dépensés → dépassement.
    // L'ancienne version du Dashboard comparait 150 à 1200 → "saine".
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 20, amount: 1200, period: .yearly)],
        transactions: [expense(1, category: 20, 150)],
        categories: categories
    )
    expectEqual(progresses[0].allocated, 100, "1200 €/an → 100 €/mois")
    expect(progresses[0].healthState == .exceeded, "150 / 100 → exceeded")
    expect(progresses[0].isOverBudget, "isOverBudget vrai")
}

// MARK: - t3 · Seuils de santé

print("\nt3 · Seuils healthy / warning / exceeded")
do {
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [
            envelope(1, category: 20, amount: 100),  // 79 € → healthy
            envelope(2, category: 20, amount: 100),  // idem, on fait varier via des lots
        ],
        transactions: [expense(1, category: 20, 79)],
        categories: categories
    )
    expect(progresses[0].healthState == .healthy, "79 % → healthy")

    let atThreshold = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 20, amount: 100)],
        transactions: [expense(1, category: 20, 80)],
        categories: categories
    )
    expect(atThreshold[0].healthState == .warning, "80 % pile → warning")

    let exact = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 20, amount: 100)],
        transactions: [expense(1, category: 20, 100)],
        categories: categories
    )
    expect(exact[0].healthState == .warning, "100 % pile → warning, pas exceeded")
    expect(!exact[0].isOverBudget, "dépenser exactement son budget n'est pas un dépassement")
}

// MARK: - t4 · rawRatio vs ratio clampé

print("\nt4 · rawRatio n'est pas clampé (sinon un dépassement est indétectable)")
do {
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 20, amount: 100)],
        transactions: [expense(1, category: 20, 250)],
        categories: categories
    )
    expectEqual(progresses[0].ratio, 1.0, "ratio reste clampé à 1.0 (largeur de barre)")
    expectEqual(progresses[0].rawRatio, 2.5, "rawRatio reflète le vrai dépassement")
    expect(progresses[0].healthState == .exceeded, "classé exceeded")
}

// MARK: - t5 · Recettes et enveloppes sans catégorie

print("\nt5 · Les recettes sont ignorées, une enveloppe sans catégorie reste à 0")
do {
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 20, amount: 100), envelope(2, category: nil, amount: 100)],
        transactions: [
            FinanceTransaction(id: 1, categoryId: 20, amount: 2500, date: now),  // salaire
            expense(2, category: 20, 30),
            FinanceTransaction(id: 3, categoryId: nil, amount: -40, date: now),  // non catégorisée
        ],
        categories: categories
    )
    expectEqual(progresses[0].spent, 30, "les montants positifs ne comptent pas comme dépense")
    expectEqual(progresses[1].spent, 0, "enveloppe sans catégorie → 0 dépensé")
    expect(progresses[1].healthState == .healthy, "et donc healthy, pas exceeded")
}

// MARK: - t6 · Part récurrente et prévisionnel

print("\nt6 · recurringSpent et forecasted via prévisions + patterns")
do {
    let pattern = RecurringPattern(
        id: 7, name: "Abonnement", amountAvg: -60, amountTolerance: 0.1,
        categoryId: 11, payeeId: nil, frequency: .monthly, anchorDay: 5,
        isActive: true, isManual: true, createdAt: now, startDate: now, endDate: nil
    )
    let previsions = [
        // Confirmée : sa transaction réelle (id 1) est la part "fixe" du dépensé.
        BudgetPrevision(id: 100, recurringPatternId: 7, amount: -60, expectedDate: now,
                        status: .matched, actualTransactionId: 1, notes: nil),
        // Encore attendue : compte dans le prévisionnel.
        BudgetPrevision(id: 101, recurringPatternId: 7, amount: -60, expectedDate: now,
                        status: .pending, actualTransactionId: nil, notes: nil),
        // Ignorée : ne doit compter nulle part.
        BudgetPrevision(id: 102, recurringPatternId: 7, amount: -60, expectedDate: now,
                        status: .skipped, actualTransactionId: nil, notes: nil),
    ]
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 10, amount: 400)],
        transactions: [expense(1, category: 11, 60), expense(2, category: 12, 40)],
        categories: categories,
        previsions: previsions,
        patterns: [pattern]
    )
    expectEqual(progresses[0].spent, 100, "total dépensé")
    expectEqual(progresses[0].recurringSpent, 60, "part issue d'un récurrent confirmé")
    expectEqual(progresses[0].variableSpent, 40, "le reste est variable")
    expectEqual(progresses[0].forecasted, 120, "prévisions matched + pending, skipped exclue")
}

// MARK: - t7 · Sans prévisions ni patterns

print("\nt7 · Appel minimal (Dashboard / alertes / widget) : pas de prévision requise")
do {
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 10, amount: 200)],
        transactions: [expense(1, category: 11, 50)],
        categories: categories
    )
    expectEqual(progresses[0].spent, 50, "dépensé calculé")
    expectEqual(progresses[0].recurringSpent, 0, "recurringSpent nul sans prévisions")
    expectEqual(progresses[0].forecasted, 0, "forecasted nul sans prévisions")
    expect(progresses[0].categoryName == "Alimentation", "libellé repris de la catégorie")
}

// MARK: - t8 · BudgetRecap

print("\nt8 · BudgetRecap agrège les états sans les recalculer")
do {
    // Catégories FEUILLES distinctes : sans ça, une enveloppe sur la parente
    // capterait aussi les dépenses des filles et fausserait le décompte attendu.
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [
            envelope(1, category: 20, amount: 100),   // 30 %  → healthy
            envelope(2, category: 11, amount: 100),   // 85 %  → warning
            envelope(3, category: 12, amount: 10),    // 900 % → exceeded
        ],
        transactions: [expense(1, category: 20, 30), expense(2, category: 11, 85), expense(3, category: 12, 90)],
        categories: categories
    )
    let recap = BudgetRecap.from(progresses)
    expect(recap.totalCount == 3, "3 enveloppes")
    expect(recap.healthyCount == 1, "1 healthy")
    expect(recap.warningCount == 1, "1 warning")
    expect(recap.exceededCount == 1, "1 exceeded")
    expect(recap.hasIssue, "hasIssue vrai dès qu'il y a warning ou exceeded")
    expect(BudgetRecap.from([]).totalCount == 0, "liste vide → recap vide")
    expect(!BudgetRecap.from([]).hasData, "et hasData faux")
}

// MARK: - t9 · Régression croisée : le cas que l'ancien AlertEngine ratait

print("\nt9 · Régression : dépense sur sous-catégorie d'une enveloppe annuelle")
do {
    // L'ancien AlertEngine ne voyait NI la sous-catégorie NI la mensualisation :
    // il comparait 0 € (catégorie exacte) à 1200 € → aucune alerte.
    let progresses = EnvelopeSpendingCalculator.progresses(
        envelopes: [envelope(1, category: 10, amount: 1200, period: .yearly)],
        transactions: [expense(1, category: 11, 130)],
        categories: categories
    )
    expectEqual(progresses[0].allocated, 100, "mensualisée")
    expectEqual(progresses[0].spent, 130, "sous-catégorie captée")
    expect(progresses[0].healthState == .exceeded, "désormais détectée comme dépassée")
}

// MARK: - Bilan

print("\n\(checks - failures)/\(checks) assertions OK")
if failures > 0 {
    print("❌ \(failures) test(s) en échec")
    exit(1)
}
print("✅ Tous les tests passent")

    }
}
