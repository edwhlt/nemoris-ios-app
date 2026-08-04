import Foundation

// Tests unitaires de la couche snapshot du Dashboard — compile le fichier RÉEL
// (DashboardSnapshot.swift) avec des stubs minimaux pour les types métier, qui n'y
// apparaissent que comme types de propriétés.
//
// Ce qui est verrouillé ici, c'est le CACHE PAR PORTÉE (`DashboardAggregateScope`).
// Sans lui, basculer le filtre mois du graphe invaliderait tout et recalculerait le
// budget, le patrimoine, les alertes et les insights — alors qu'aucun d'eux ne
// regarde le mois affiché. L'ancien `AnnualDashboardViewModel.toggleMonth` ne
// refetchait que les catégories et les tags ; t4 et t5 garantissent qu'on n'a pas
// régressé là-dessus en passant au cache.

// MARK: - Stubs des types de l'app
//
// `DashboardSnapshot` ne fait que les STOCKER (aucun accès à leurs membres), donc
// des coquilles vides suffisent et évitent de recopier tout le modèle métier.

struct MonthlyTotals {}
struct DashboardStats {}
struct CategoryTotal {}
struct TagTotal {}
struct EnvelopeProgress {}
struct BudgetRecap {}
struct InvestmentsRecap {}
struct PatrimoineSnapshot {}
struct Alert {}
struct Insight {}

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

let calendar = Calendar.current

func day(_ date: Date) -> (y: Int, m: Int, d: Int) {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

@main
enum DashboardSnapshotTests {
    static func main() {

// MARK: - t1 · Bornes de l'exercice

print("\nt1 · L'exercice couvre du 1er janvier au 31 décembre")
do {
    let period = DashboardPeriod(year: 2026, month: nil)
    expect(day(period.yearFrom) == (2026, 1, 1), "yearFrom = 1er janvier")
    expect(day(period.yearTo) == (2026, 12, 31), "yearTo = 31 décembre")
    expect(day(period.filterFrom) == day(period.yearFrom), "sans filtre mois, filterFrom = yearFrom")
    expect(day(period.filterTo) == day(period.yearTo), "sans filtre mois, filterTo = yearTo")
    expect(period.monthLabel == nil, "pas de libellé de mois sans filtre")
    if let from = period.previousYearFrom, let to = period.previousYearTo {
        expect(day(from) == (2025, 1, 1) && day(to) == (2025, 12, 31), "comparaison N-1 sur 2025")
    } else {
        expect(false, "comparaison N-1 sur 2025", "dates nil")
    }
}

// MARK: - t2 · Filtre mois

print("\nt2 · Le filtre mois borne la fenêtre de détail sur le mois")
do {
    let period = DashboardPeriod(year: 2026, month: "2026-07")
    expect(day(period.filterFrom) == (2026, 7, 1), "filterFrom = 1er juillet")
    expect(day(period.filterTo) == (2026, 7, 31), "filterTo = 31 juillet")
    expect(period.monthLabel != nil, "libellé de mois présent")

    // Décembre : le calcul +1 mois −1 jour doit rester dans l'année.
    let december = DashboardPeriod(year: 2026, month: "2026-12")
    expect(day(december.filterTo) == (2026, 12, 31), "décembre se termine le 31, pas en janvier")

    // Février bissextile — le calendrier fait le travail, on vérifie qu'on ne
    // code pas une durée de mois en dur quelque part.
    let february = DashboardPeriod(year: 2024, month: "2024-02")
    expect(day(february.filterTo) == (2024, 2, 29), "février 2024 se termine le 29")
}

print("\nt2b · Un mois mal formé retombe sur l'année entière")
do {
    // Le parsing est manuel (pas de DateFormatter, non Sendable) : on vérifie qu'il
    // ne produit pas de date aberrante sur une entrée invalide.
    for bad in ["2026-13", "n'importe quoi", "2026", "2026-07-15", ""] {
        let period = DashboardPeriod(year: 2026, month: bad)
        expect(day(period.filterFrom) == (2026, 1, 1) && day(period.filterTo) == (2026, 12, 31),
               "« \(bad) » → année entière")
    }
}

// MARK: - t3 · Dépendances entre agrégats

print("\nt3 · Les dépendances entre agrégats sont résolues")
do {
    let expanded = DashboardAggregate.expanded([.alerts])
    expect(expanded.contains(.budgetEnvelopes), "les alertes tirent les enveloppes (elles lisent les EnvelopeProgress)")
    expect(DashboardAggregate.expanded([.insights]) == [.insights], "un agrégat sans dépendance reste seul")

    // L'ordre d'évaluation doit couvrir tous les cas et placer les producteurs avant
    // leurs consommateurs, sinon `.alerts` lirait un snapshot vide.
    let order = DashboardAggregate.evaluationOrder
    expect(Set(order) == Set(DashboardAggregate.allCases), "tous les agrégats sont dans l'ordre d'évaluation")
    expect(order.count == DashboardAggregate.allCases.count, "aucun doublon dans l'ordre d'évaluation")
    for unit in DashboardAggregate.allCases {
        guard let index = order.firstIndex(of: unit) else { continue }
        for required in unit.requires {
            guard let requiredIndex = order.firstIndex(of: required) else { continue }
            expect(requiredIndex < index, "\(required.rawValue) est évalué avant \(unit.rawValue)")
        }
    }
}

// MARK: - t4 · Cache par portée — le filtre mois

print("\nt4 · Changer de mois n'invalide QUE les catégories et les tags")
do {
    let token = UUID()
    let before = DashboardCacheKey(refreshToken: token, period: DashboardPeriod(year: 2026, month: nil))
    let after  = DashboardCacheKey(refreshToken: token, period: DashboardPeriod(year: 2026, month: "2026-07"))

    let invalidated = DashboardAggregate.allCases.filter { before.unitKey(for: $0) != after.unitKey(for: $0) }
    expect(Set(invalidated) == [.categoryBreakdown, .tagBreakdown],
           "seuls categoryBreakdown et tagBreakdown sont recalculés",
           "invalidés : \(invalidated.map(\.rawValue).sorted())")
}

print("\nt5 · Changer d'exercice invalide la série annuelle et le détail")
do {
    let token = UUID()
    let before = DashboardCacheKey(refreshToken: token, period: DashboardPeriod(year: 2026, month: nil))
    let after  = DashboardCacheKey(refreshToken: token, period: DashboardPeriod(year: 2025, month: nil))

    let invalidated = Set(DashboardAggregate.allCases.filter { before.unitKey(for: $0) != after.unitKey(for: $0) })
    expect(invalidated.contains(.yearSeries), "la série annuelle est recalculée")
    expect(invalidated.contains(.categoryBreakdown) && invalidated.contains(.tagBreakdown),
           "le détail catégories/tags suit l'exercice")
    // Budget, patrimoine, investissements, alertes et insights portent sur "maintenant" :
    // changer d'exercice affiché ne doit pas les faire retravailler.
    expect(!invalidated.contains(.patrimoine) && !invalidated.contains(.budgetEnvelopes)
           && !invalidated.contains(.insights) && !invalidated.contains(.investments)
           && !invalidated.contains(.alerts),
           "les agrégats « au présent » ne sont pas recalculés",
           "invalidés : \(invalidated.map(\.rawValue).sorted())")
}

print("\nt6 · Un nouveau refreshToken invalide TOUT")
do {
    let period = DashboardPeriod(year: 2026, month: "2026-03")
    let before = DashboardCacheKey(refreshToken: UUID(), period: period)
    let after  = DashboardCacheKey(refreshToken: UUID(), period: period)

    let stable = DashboardAggregate.allCases.filter { before.unitKey(for: $0) == after.unitKey(for: $0) }
    expect(stable.isEmpty, "aucun agrégat ne survit à une mutation de données",
           "stables : \(stable.map(\.rawValue))")
}

// MARK: - t7 · Fusion partielle

print("\nt7 · La passe lourde fusionne sans effacer la passe légère")
do {
    var light = DashboardSnapshot()
    light.stats = DashboardStats()
    light.budget = BudgetRecap()

    var heavy = DashboardSnapshot()
    heavy.insights = [Insight()]

    let merged = light.merging(heavy)
    expect(merged.stats != nil, "les stats de la passe légère survivent")
    expect(merged.budget != nil, "le budget de la passe légère survit")
    expect(merged.insights?.count == 1, "les insights de la passe lourde sont ajoutés")
    expect(merged.patrimoine == nil, "un agrégat jamais calculé reste nil (→ squelette de la carte)")

    // Une passe vide ne doit rien effacer (cas d'un agrégat sans donnée).
    let untouched = merged.merging(DashboardSnapshot())
    expect(untouched.stats != nil && untouched.insights?.count == 1, "une passe vide n'efface rien")
}

// MARK: - t8 · Coût des agrégats

print("\nt8 · Seuls les agrégats réellement lourds sont différés")
do {
    let expensive = DashboardAggregate.allCases.filter(\.isExpensive)
    expect(expensive == [.insights], "insights est le seul agrégat de seconde passe",
           "trouvés : \(expensive.map(\.rawValue))")
    // Les insights font leur propre scan sur 180 jours : ils ne doivent partager
    // aucune source, sinon on la fetcherait deux fois (une par passe).
    expect(DashboardAggregate.insights.sources.isEmpty, "insights ne partage aucune source brute")
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
