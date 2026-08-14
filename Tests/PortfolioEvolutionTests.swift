import Foundation

// Tests unitaires de PortfolioEvolutionBuilder — compile le fichier RÉEL avec
// des stubs minimaux (aucune dépendance SwiftUI/Charts/base de données).
//
// Régression principale verrouillée ici : le chart agrégé "en dents de scie".
// Cause historique = repli sur le PRU (`averageBuyPrice`) quand un pas de la
// grille n'avait pas de cours pour une position. Le PRU étant un COÛT et pas un
// cours, il peut être sur une tout autre échelle (PRU 250 € pour un titre qui
// cote 40 €) : chaque repli faisait bondir le total au montant investi.
// Combiné à une grille = union d'horodatages DÉSALIGNÉS entre séries, ça
// alternait point par point.

// MARK: - Stubs des types de l'app

struct InvestmentPricePoint {
    let id: String
    let identifier: String
    let date: Date
    let close: Double
}

struct PortfolioEvolutionPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

enum InvestmentTimeRange {
    case oneDay, oneWeek, oneMonth, threeMonth, sixMonth, oneYear, fiveYear, tenYear, all
    var startDate: Date? {
        let cal = Calendar.current, now = Date()
        switch self {
        case .oneDay:     return cal.date(byAdding: .day,   value: -1,  to: now)
        case .oneWeek:    return cal.date(byAdding: .day,   value: -7,  to: now)
        case .oneMonth:   return cal.date(byAdding: .month, value: -1,  to: now)
        case .threeMonth: return cal.date(byAdding: .month, value: -3,  to: now)
        case .sixMonth:   return cal.date(byAdding: .month, value: -6,  to: now)
        case .oneYear:    return cal.date(byAdding: .year,  value: -1,  to: now)
        case .fiveYear:   return cal.date(byAdding: .year,  value: -5,  to: now)
        case .tenYear:    return cal.date(byAdding: .year,  value: -10, to: now)
        case .all:        return nil
        }
    }
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

/// Amplitude relative pic-à-creux, en %. Sur des cours stables, une valeur
/// élevée (> 30 %) est la signature du dentelé.
func amplitude(_ points: [PortfolioEvolutionPoint]) -> Double {
    guard let lo = points.map(\.value).min(), let hi = points.map(\.value).max(), lo > 0 else { return 0 }
    return (hi - lo) / lo * 100
}

let cal = Calendar.current
let now = Date()

func dayPoint(_ daysAgo: Int, hour: Int, close: Double, id: String) -> InvestmentPricePoint {
    let base = cal.date(byAdding: .day, value: -daysAgo, to: now)!
    let date = cal.date(bySettingHour: hour, minute: 5, second: 0, of: base)!
    return InvestmentPricePoint(id: "\(id)\(daysAgo)", identifier: id, date: date, close: close)
}

/// Scénario réel : 2 positions d'un même PEA, synchronisées à des heures
/// DIFFÉRENTES (09h vs 17h) → grilles d'horodatages désalignées.
///   Lyxor CAC 40 : 30 parts à ~84 €   → ~2 530 €  (PRU  71 →  2 130 €)
///   Epargne World : 45 parts à ~40 €   → ~1 818 €  (PRU 250 → 11 250 €)
///   Valeur de marché attendue ≈ 4 350 € ; total au PRU = 13 380 €
func realisticInputs() -> [PortfolioSeriesInput] {
    var lyxor: [InvestmentPricePoint] = []
    var epargne: [InvestmentPricePoint] = []
    for d in stride(from: 89, through: 0, by: -1) {
        lyxor.append(dayPoint(d, hour: 9,  close: 84.0 + Double((89 - d) % 7) * 0.15, id: "CAC.PA"))
        epargne.append(dayPoint(d, hour: 17, close: 40.0 + Double((89 - d) % 5) * 0.08, id: "EWLD.PA"))
    }
    return [
        PortfolioSeriesInput(positionId: 1, quantity: 30, history: lyxor),
        PortfolioSeriesInput(positionId: 2, quantity: 45, history: epargne),
    ]
}

@main
enum PortfolioEvolutionTests {
    static func main() {

// MARK: - t1 — Pas de dents de scie sur séries désalignées

print("\nt1 · Séries désalignées : la courbe reste dans l'échelle du marché")
do {
    let result = PortfolioEvolutionBuilder.build(inputs: realisticInputs(), range: .threeMonth, now: now)
    let amp = amplitude(result.points)
    expect(amp < 10, "amplitude < 10 %", String(format: "amplitude = %.1f %%", amp))
    let maxValue = result.points.map(\.value).max() ?? 0
    // 13 380 € = total au PRU. La courbe ne doit JAMAIS s'en approcher.
    expect(maxValue < 6_000, "aucun pic vers le montant investi (13 380 €)",
           String(format: "max = %.0f €", maxValue))
    expect(result.unpricedPositionIds.isEmpty, "aucune position marquée sans cours")
}

// MARK: - t2 — Le PRU n'entre jamais dans la valorisation

print("\nt2 · Une position sans aucun cours est EXCLUE, jamais valorisée au PRU")
do {
    let orphan = PortfolioSeriesInput(positionId: 99, quantity: 1000, history: [])
    let result = PortfolioEvolutionBuilder.build(inputs: realisticInputs() + [orphan],
                                                 range: .threeMonth, now: now)
    expect(result.unpricedPositionIds == [99], "position orpheline signalée à l'UI",
           "\(result.unpricedPositionIds.sorted())")
    let maxValue = result.points.map(\.value).max() ?? 0
    expect(maxValue < 6_000, "la position orpheline n'a pas gonflé le total",
           String(format: "max = %.0f €", maxValue))
}

// MARK: - t3 — Grille régulière : un seul point par pas de temps

print("\nt3 · Grille régulière, dates strictement croissantes et uniques")
do {
    let result = PortfolioEvolutionBuilder.build(inputs: realisticInputs(), range: .threeMonth, now: now)
    let dates = result.points.map(\.date)
    expect(dates == dates.sorted(), "dates triées")
    expect(Set(dates).count == dates.count, "aucune date en double",
           "\(dates.count) points, \(Set(dates).count) uniques")
    expect(result.points.count <= 160, "nombre de points borné",
           "\(result.points.count) points")
}

// MARK: - t4 — Vue 1J utilisable même si l'intraday est partiel

print("\nt4 · 1J : grille 30 min même quand une position n'a que du quotidien")
do {
    var intraday: [InvestmentPricePoint] = []
    for step in stride(from: 47, through: 0, by: -1) {
        intraday.append(InvestmentPricePoint(
            id: "I\(step)", identifier: "CAC.PA",
            date: now.addingTimeInterval(-Double(step) * 1800),
            close: 84.0 + Double(47 - step) * 0.01))
    }
    let dailyOnly = realisticInputs()[1]   // Epargne : quotidien uniquement
    let result = PortfolioEvolutionBuilder.build(
        inputs: [PortfolioSeriesInput(positionId: 1, quantity: 30, history: intraday), dailyOnly],
        range: .oneDay, now: now)
    // Avant : 2 points (union d'horodatages quasi vide sur 24 h).
    expect(result.points.count >= 40, "au moins 40 points sur 24 h",
           "\(result.points.count) points")
    let amp = amplitude(result.points)
    expect(amp < 10, "pas de dentelé en 1J", String(format: "amplitude = %.1f %%", amp))
}

// MARK: - t5 — Back-fill : pas de marche artificielle en début de courbe

print("\nt5 · Back-fill : une position qui démarre en retard ne crée pas de marche")
do {
    // Position A sur toute la plage, position B seulement sur les 10 derniers jours.
    var full: [InvestmentPricePoint] = []
    var late: [InvestmentPricePoint] = []
    for d in stride(from: 89, through: 0, by: -1) {
        full.append(dayPoint(d, hour: 9, close: 100, id: "A"))
        if d <= 10 { late.append(dayPoint(d, hour: 17, close: 50, id: "B")) }
    }
    let result = PortfolioEvolutionBuilder.build(
        inputs: [PortfolioSeriesInput(positionId: 1, quantity: 10, history: full),
                 PortfolioSeriesInput(positionId: 2, quantity: 10, history: late)],
        range: .threeMonth, now: now)
    // 10×100 + 10×50 = 1500 partout grâce au back-fill du premier cours de B.
    let amp = amplitude(result.points)
    expect(amp < 1, "courbe plate malgré le démarrage tardif",
           String(format: "amplitude = %.2f %%", amp))
}

// MARK: - t6 — Robustesse aux valeurs dégénérées

print("\nt6 · Cours non finis / négatifs ignorés")
do {
    var dirty: [InvestmentPricePoint] = []
    for d in stride(from: 30, through: 0, by: -1) {
        dirty.append(dayPoint(d, hour: 9, close: d % 5 == 0 ? -1 : 100, id: "D"))
    }
    dirty.append(InvestmentPricePoint(id: "nan", identifier: "D", date: now, close: .nan))
    let result = PortfolioEvolutionBuilder.build(
        inputs: [PortfolioSeriesInput(positionId: 1, quantity: 10, history: dirty)],
        range: .threeMonth, now: now)
    expect(result.points.allSatisfy { $0.value.isFinite }, "toutes les valeurs sont finies")
    let amp = amplitude(result.points)
    expect(amp < 1, "les valeurs invalides n'ont pas créé de pics",
           String(format: "amplitude = %.2f %%", amp))
}

// MARK: - t7 — 1J hors séance : la grille s'ancre sur la dernière cotation

print("\nt7 · 1J consulté hors séance (week-end) : la dernière séance reste visible")
do {
    // Simule un samedi après-midi : la dernière cotation date de vendredi
    // 17 h 30, soit ~46 h avant `now`. Une grille [now-24h, now] ne contient
    // alors AUCUN point réel → la courbe s'aplatissait sur une seule valeur
    // back-fillée (le symptôme « 1J n'affiche que 2 points »).
    var session: [InvestmentPricePoint] = []
    let lastQuote = now.addingTimeInterval(-46 * 3600)
    for step in stride(from: 15, through: 0, by: -1) {
        session.append(InvestmentPricePoint(
            id: "S\(step)", identifier: "EWLD.PA",
            date: lastQuote.addingTimeInterval(-Double(step) * 1800),
            close: 40.0 + Double(15 - step) * 0.02))
    }
    let result = PortfolioEvolutionBuilder.build(
        inputs: [PortfolioSeriesInput(positionId: 1, quantity: 100, history: session)],
        range: .oneDay, now: now)

    expect(result.points.count >= 15, "la séance cotée est bien tracée",
           "\(result.points.count) points")
    // La courbe doit refléter la variation réelle de la séance (+0.30 € sur
    // 40 €, ×100 titres) et pas une ligne parfaitement plate.
    let amp = amplitude(result.points)
    expect(amp > 0.1, "la variation de la séance est visible",
           String(format: "amplitude = %.2f %%", amp))
    expect(result.points.last.map { $0.date <= now } ?? false,
           "la grille ne dépasse pas l'instant présent")
    expect(result.unpricedPositionIds.isEmpty, "position valorisée normalement")
}

// MARK: - Verdict

print("\n\(checks - failures)/\(checks) assertions OK")
if failures > 0 {
    print("❌ \(failures) échec(s)")
    exit(1)
}
print("✅ Tous les tests passent")

    }
}
