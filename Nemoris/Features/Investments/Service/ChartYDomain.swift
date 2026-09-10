import Foundation

/// Domaine vertical d'un graphique de cours ou de valorisation.
///
/// Règle unique : **l'échelle vient de la série effectivement tracée sur la
/// plage sélectionnée**, jamais d'une valeur qui vit en dehors. Sans ça,
/// changer de plage ne fait varier que l'abscisse — l'ordonnée reste étirée
/// par un repère hors champ, la courbe se tasse sur quelques pixels et se lit
/// comme une droite alors qu'elle bouge.
///
/// Deux pièges concrets, tous deux rencontrés sur la fiche position :
///
/// 1. **Un repère hors plage impose l'échelle.** Le PRU d'un titre acheté
///    250 € qui cote 40 € force un domaine 0–270 sur TOUTES les plages ; le
///    mouvement réel du mois (39 → 41 €) devient invisible. D'où
///    `references` : ces valeurs n'ont le droit d'élargir le domaine que si
///    elles tombent à portée de la série (`referenceTolerance`), sinon elles
///    sont ignorées — au dessinateur de masquer le repère devenu hors champ
///    (`domaine.contains(repère)`).
///
/// 2. **Un padding proportionnel à la VALEUR au lieu de l'AMPLITUDE.** Un
///    `lo * 0.92 ... hi * 1.08` sur une série 39–41 € donne 35,9–44,3 : le
///    padding vaut quatre fois l'amplitude réelle et écrase la courbe à lui
///    seul, PRU ou pas. Ici le padding est une fraction de l'amplitude.
enum ChartYDomain {

    /// Domaine de repli quand il n'y a strictement rien à représenter.
    static let fallback: ClosedRange<Double> = 0...1

    /// - Parameters:
    ///   - values: la série TRACÉE sur la plage affichée. Elle seule fixe l'échelle.
    ///   - references: repères secondaires (PRU, cours d'un ordre) qui ne doivent
    ///     pas imposer l'échelle. Ils n'élargissent le domaine que s'ils tombent
    ///     à portée de la série.
    ///   - padding: respiration haute et basse, en fraction de l'amplitude.
    ///   - referenceTolerance: distance maximale, en fraction de l'amplitude, à
    ///     laquelle un repère peut encore élargir le domaine.
    ///   - clampToZero: borne basse à 0 — pour un cours ou une valorisation,
    ///     qui ne descendent pas sous zéro.
    static func compute(values: [Double],
                        references: [Double] = [],
                        padding: Double = 0.12,
                        referenceTolerance: Double = 0.6,
                        clampToZero: Bool = false) -> ClosedRange<Double> {
        let série = values.filter(\.isFinite)
        let repères = references.filter(\.isFinite)

        guard let bas = série.min(), let haut = série.max() else {
            // Pas de série : les repères redeviennent la seule information
            // disponible, et à ce titre reprennent le droit de fixer l'échelle.
            guard let basRepère = repères.min(), let hautRepère = repères.max() else {
                return fallback
            }
            return padded(basRepère, hautRepère, padding: padding, clampToZero: clampToZero)
        }

        // Amplitude plancher : une série plate ne doit donner ni un domaine
        // dégénéré, ni une tolérance nulle qui exclurait jusqu'au repère collé
        // à la courbe.
        let amplitude = floorSpan(bas, haut)
        let marge = amplitude * max(0, referenceTolerance)

        var bornBas = bas
        var bornHaut = haut
        for repère in repères {
            if repère < bornBas, repère >= bas - marge {
                bornBas = repère
            } else if repère > bornHaut, repère <= haut + marge {
                bornHaut = repère
            }
        }

        return padded(bornBas, bornHaut, padding: padding, clampToZero: clampToZero)
    }

    /// Amplitude retenue pour le calcul : jamais nulle, et au moins 2 % de la
    /// valeur affichée pour qu'une série parfaitement plate garde une bande
    /// lisible plutôt qu'un trait au milieu d'un domaine microscopique.
    private static func floorSpan(_ bas: Double, _ haut: Double) -> Double {
        max(haut - bas, abs(haut) * 0.02, 0.0001)
    }

    private static func padded(_ bas: Double, _ haut: Double,
                               padding: Double, clampToZero: Bool) -> ClosedRange<Double> {
        let marge = floorSpan(bas, haut) * max(0, padding)
        let bornBas = clampToZero ? max(0, bas - marge) : bas - marge
        let bornHaut = haut + marge
        // `ClosedRange` exige lower <= upper : un clamp à zéro sur une série
        // elle-même à zéro pourrait sinon produire une plage inversée.
        return bornBas...max(bornHaut, bornBas + 0.0001)
    }
}
