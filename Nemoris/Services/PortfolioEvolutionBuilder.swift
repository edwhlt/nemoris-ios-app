import Foundation

// MARK: - Construction robuste des courbes d'évolution agrégées
//
// Ce moteur remplace l'agrégation "maison" qui vivait dans InvestmentsViewModel
// (niveau global ET niveau compte). Il est PUR (aucun accès base/cache/réseau),
// donc déterministe et testable.
//
// ─── Les 3 défauts structurels de l'ancienne version ───────────────────────
//
// 1. GRILLE = UNION DES HORODATAGES BRUTS.
//    Deux positions synchronisées par des sources différentes n'ont pas les
//    mêmes heures (09:05Z vs 17:35Z). L'union produisait une grille irrégulière
//    où, à chaque instant, une seule des séries avait "vraiment" un point.
//
// 2. REPLI SUR LE PRU (`averageBuyPrice`) quand aucun prix n'était connu.
//    C'est LE défaut critique : le PRU est un COÛT D'ACQUISITION, pas un cours.
//    Il peut être sur une tout autre échelle que le prix de marché (PRU 250 €
//    pour un titre qui cote 40 €). Chaque repli faisait donc bondir le total de
//    plusieurs milliers d'euros → les fameuses "dents de scie", avec des pics
//    qui valaient exactement le montant investi.
//
// 3. FORWARD-FILL SEUL, pas de back-fill : avant le premier point d'une
//    position, on retombait sur le PRU (cf. 2) au lieu de son premier cours connu.
//
// ─── Garanties de la nouvelle version ──────────────────────────────────────
//
// • Grille RÉGULIÈRE (pas de bucket vide, pas d'alternance) → un seul point par
//   pas de temps, condition nécessaire d'un rendu Swift Charts propre.
// • Le PRU n'entre JAMAIS dans une courbe de valorisation. Une position sans
//   aucun cours est EXCLUE de la courbe et signalée à l'appelant (diagnostic),
//   plutôt que d'empoisonner l'agrégat avec une valeur d'une autre échelle.
// • Back-fill + forward-fill avec les propres cours de la position (premier
//   cours connu avant son historique, dernier cours connu après).
// • Nombre de points BORNÉ (~150 max) : les charts restent fluides et les
//   labels d'axe lisibles quelle que soit la plage.

/// Une position prête à être agrégée : sa quantité et son historique de cours
/// DÉJÀ résolu (ISIN → ticker → symbole de sync) et trié.
struct PortfolioSeriesInput {
    let positionId: Int
    let quantity: Double
    let history: [InvestmentPricePoint]
}

enum PortfolioEvolutionBuilder {

    /// Nombre de points visé pour une courbe. Borne haute : au-delà, les labels
    /// d'axe se chevauchent et le rendu se dégrade sans gain d'information.
    private static let targetPointCount = 150

    struct Result {
        /// Courbe agrégée, un point par pas de la grille, triée.
        let points: [PortfolioEvolutionPoint]
        /// Positions effectivement valorisées avec un vrai cours.
        let pricedPositionIds: Set<Int>
        /// Positions SANS aucun cours sur la plage → exclues de la courbe.
        /// L'UI doit les signaler (« X positions sans historique »).
        let unpricedPositionIds: Set<Int>
    }

    /// Construit la courbe agrégée sur une grille temporelle régulière.
    ///
    /// - Parameters:
    ///   - inputs: positions + historiques résolus.
    ///   - range: plage sélectionnée (détermine le début et le pas de la grille).
    ///   - now: injectable pour les tests.
    static func build(inputs: [PortfolioSeriesInput],
                      range: InvestmentTimeRange,
                      now: Date = Date()) -> Result {

        // 1. Séparer les positions valorisables de celles sans aucun cours.
        //    Une position sans cours est EXCLUE (jamais remplacée par son PRU).
        var priced: [PortfolioSeriesInput] = []
        var unpriced: Set<Int> = []
        for input in inputs {
            let usable = input.history.filter { $0.close.isFinite && $0.close > 0 }
            if usable.isEmpty {
                unpriced.insert(input.positionId)
            } else {
                priced.append(PortfolioSeriesInput(
                    positionId: input.positionId,
                    quantity: input.quantity,
                    history: usable.sorted { $0.date < $1.date }
                ))
            }
        }
        guard !priced.isEmpty else {
            return Result(points: [], pricedPositionIds: [], unpricedPositionIds: unpriced)
        }

        // 2. Bornes de la grille.
        //    Fin = maintenant (le présent est la référence ; une série qui
        //    s'arrête hier donne un palier plat jusqu'à maintenant, ce qui est
        //    honnête et évite un chart qui "s'arrête" sans raison visible).
        //    Début = début de plage, ou le plus ancien cours connu pour « Max ».
        let earliest = priced.compactMap { $0.history.first?.date }.min() ?? now
        let latest = priced.compactMap { $0.history.last?.date }.max() ?? now

        // Cas particulier de la plage 1J : la grille est ancrée sur la dernière
        // cotation, pas sur `now`. Hors séance (soir, week-end, avant
        // l'ouverture) la dernière séance est entièrement à plus de 24 h, donc
        // une grille [now-24h, now] ne contiendrait AUCUN point réel : la
        // courbe s'aplatissait sur une seule valeur back-fillée. On montre
        // plutôt les dernières 24 h COTÉES — même règle que le chart de
        // position (cf. `lastQuotedWindow`).
        let oneDayWindow: TimeInterval = 86_400
        let start: Date
        let end: Date
        if range == .oneDay, latest < now.addingTimeInterval(-oneDayWindow) {
            end = latest
            start = max(latest.addingTimeInterval(-oneDayWindow), earliest)
        } else {
            start = max(range.startDate ?? earliest, earliest)
            end = max(now, latest)
        }
        guard end > start else {
            // Plage dégénérée (une seule date) : un point unique, pas de grille.
            let total = priced.reduce(0.0) { acc, input in
                acc + input.quantity * (input.history.last?.close ?? 0)
            }
            return Result(
                points: [PortfolioEvolutionPoint(date: end, value: total)],
                pricedPositionIds: Set(priced.map(\.positionId)),
                unpricedPositionIds: unpriced
            )
        }

        // 3. Pas de la grille. Plancher = granularité réelle de la donnée
        //    (30 min en intraday sur 1J, sinon 1 jour) — descendre plus fin ne
        //    ferait que dupliquer des valeurs. Plafond = span / targetPointCount.
        let span = end.timeIntervalSince(start)
        let minimumBucket: TimeInterval = (range == .oneDay) ? 1800 : 86_400
        let bucket = max(minimumBucket, span / Double(targetPointCount))

        // 4. Normaliser chaque série sur la grille : pour chaque bucket, le
        //    DERNIER cours observé dans ce bucket (clôture du pas).
        //    Puis back-fill (avant le 1er cours) et forward-fill (après).
        let bucketCount = max(1, Int((span / bucket).rounded(.up)))
        var totals = [Double](repeating: 0, count: bucketCount + 1)

        for input in priced {
            var bucketPrice = [Double?](repeating: nil, count: bucketCount + 1)
            for point in input.history {
                let offset = point.date.timeIntervalSince(start)
                // Les points antérieurs au début de grille servent de valeur
                // initiale (index 0) : c'est ce qui permet un back-fill correct.
                let index = offset <= 0 ? 0 : min(bucketCount, Int(offset / bucket))
                bucketPrice[index] = point.close   // dernier gagne (série triée)
            }

            // Back-fill : avant le premier cours connu, on utilise CE cours
            // (jamais le PRU) → pas de marche artificielle en début de courbe.
            let firstKnown = bucketPrice.compactMap { $0 }.first ?? 0
            var carried = firstKnown
            for index in 0...bucketCount {
                if let price = bucketPrice[index] {
                    carried = price          // nouveau cours observé
                }
                // carried = forward-fill du dernier cours connu
                totals[index] += input.quantity * carried
            }
        }

        // 5. Émettre la courbe.
        var points: [PortfolioEvolutionPoint] = []
        points.reserveCapacity(bucketCount + 1)
        for index in 0...bucketCount {
            let date = start.addingTimeInterval(Double(index) * bucket)
            points.append(PortfolioEvolutionPoint(date: min(date, end), value: totals[index]))
        }

        // Un seul point par date (le dernier bucket peut être clampé à `end`).
        var seen = Set<Date>()
        let deduped = points.filter { seen.insert($0.date).inserted }

        return Result(
            points: deduped,
            pricedPositionIds: Set(priced.map(\.positionId)),
            unpricedPositionIds: unpriced
        )
    }
}
