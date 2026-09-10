import Foundation
import Testing
@testable import Nemoris

/// Échelle verticale des graphiques d'investissement.
///
/// Le symptôme que ce moteur existe pour empêcher : changer de plage
/// temporelle fait bien varier l'abscisse, mais l'ordonnée reste étirée par
/// une valeur hors champ — la courbe se tasse sur quelques pixels et se lit
/// comme une droite alors qu'elle bouge.
@Suite("ChartYDomain")
struct ChartYDomainTests {

    // MARK: - Le cas qui a motivé le moteur

    @Test("Un PRU très éloigné n'impose pas l'échelle")
    func pruHorsPlageIgnoré() {
        // Titre acheté 250 €, qui cote aujourd'hui autour de 40 €.
        let domaine = ChartYDomain.compute(values: [39, 40, 41],
                                           references: [250],
                                           padding: 0.08,
                                           clampToZero: true)

        #expect(!domaine.contains(250))
        // L'amplitude reste celle de la courbe (2 €) plus un padding modeste,
        // pas les 211 € que le PRU imposerait.
        #expect(domaine.upperBound - domaine.lowerBound < 3)
        #expect(domaine.contains(39))
        #expect(domaine.contains(41))
    }

    @Test("Un PRU proche élargit bien le domaine")
    func pruProcheRetenu() {
        // Ici le PRU est à portée : il doit rester visible, c'est son intérêt
        // (seuil de break-even lisible sous la courbe).
        let domaine = ChartYDomain.compute(values: [39, 40, 41],
                                           references: [38.5],
                                           padding: 0.08,
                                           clampToZero: true)

        #expect(domaine.contains(38.5))
        #expect(domaine.lowerBound < 38.5)
    }

    @Test("Le padding suit l'amplitude, pas la valeur absolue")
    func paddingProportionnelÀLAmplitude() {
        // Régression du second défaut : un padding `lo * 0.92 ... hi * 1.08`
        // sur une série 39–41 € donnait 35,9–44,3 — un padding valant quatre
        // fois l'amplitude réelle, qui écrasait la courbe à lui seul.
        let domaine = ChartYDomain.compute(values: [39, 40, 41], padding: 0.08)

        let amplitudeSérie = 2.0
        let amplitudeDomaine = domaine.upperBound - domaine.lowerBound
        #expect(amplitudeDomaine < amplitudeSérie * 1.5)
        #expect(domaine.lowerBound > 38)
        #expect(domaine.upperBound < 42)
    }

    @Test("Changer de plage rééquilibre l'échelle")
    func échelleSuitLaPlage() {
        // Même titre, deux fenêtres : la fenêtre courte doit obtenir une
        // échelle serrée, sinon son mouvement propre reste invisible.
        let longue = ChartYDomain.compute(values: [10, 55, 40, 41, 39, 40])
        let courte = ChartYDomain.compute(values: [41, 39, 40])

        #expect(courte.upperBound - courte.lowerBound
                < (longue.upperBound - longue.lowerBound) / 10)
    }

    // MARK: - Séries dégénérées

    @Test("Une série parfaitement plate garde une bande lisible")
    func sériePlate() {
        let domaine = ChartYDomain.compute(values: [100, 100, 100])

        #expect(domaine.lowerBound < 100)
        #expect(domaine.upperBound > 100)
        #expect(domaine.upperBound - domaine.lowerBound > 0)
    }

    @Test("Une série vide retombe sur les repères, puis sur le repli")
    func sérieVide() {
        // Sans série, le repère redevient la seule information disponible et
        // reprend à ce titre le droit de fixer l'échelle.
        let avecRepère = ChartYDomain.compute(values: [], references: [42])
        #expect(avecRepère.contains(42))

        #expect(ChartYDomain.compute(values: [], references: []) == ChartYDomain.fallback)
    }

    @Test("Les valeurs non finies sont écartées")
    func valeursNonFinies() {
        let domaine = ChartYDomain.compute(values: [39, .nan, 41, .infinity])

        #expect(domaine.contains(39))
        #expect(domaine.contains(41))
        #expect(domaine.upperBound.isFinite)
        #expect(domaine.lowerBound.isFinite)
    }

    // MARK: - Bornes

    @Test("clampToZero empêche une borne basse négative")
    func clampÀZéro() {
        let domaine = ChartYDomain.compute(values: [0.05, 0.1], clampToZero: true)
        #expect(domaine.lowerBound >= 0)
        #expect(domaine.lowerBound <= domaine.upperBound)
    }

    @Test("Une série entièrement nulle produit une plage valide")
    func sérieNulle() {
        // Garde-fou : `ClosedRange` exige lower <= upper, un clamp à zéro sur
        // une série elle-même à zéro pourrait sinon inverser la plage.
        let domaine = ChartYDomain.compute(values: [0, 0], clampToZero: true)
        #expect(domaine.lowerBound <= domaine.upperBound)
    }

    @Test("Un repère peut élargir vers le haut comme vers le bas")
    func repèresDesDeuxCôtés() {
        let domaine = ChartYDomain.compute(values: [40, 41],
                                           references: [39.5, 41.5],
                                           padding: 0.08)
        #expect(domaine.contains(39.5))
        #expect(domaine.contains(41.5))
    }

    @Test("La tolérance se mesure en fraction de l'amplitude")
    func toléranceRelative() {
        // Amplitude 10 (40→50), tolérance 0,6 ⇒ un repère est retenu jusqu'à
        // 6 unités sous la courbe, pas au-delà.
        let retenu = ChartYDomain.compute(values: [40, 50], references: [35],
                                          referenceTolerance: 0.6)
        #expect(retenu.contains(35))

        let écarté = ChartYDomain.compute(values: [40, 50], references: [30],
                                          referenceTolerance: 0.6)
        #expect(!écarté.contains(30))
    }
}
