import Foundation
import Testing
@testable import Nemoris

/// The vertical scale of investment charts.
///
/// The symptom this engine exists to prevent: switching time
/// ranges does move the x-axis, but the y-axis stays stretched by
/// an out-of-range value — the curve squeezes into a few pixels and reads
/// like a flat line even though it's moving.
@Suite("ChartYDomain")
struct ChartYDomainTests {

    // MARK: - The case that motivated the engine

    @Test("Un PRU très éloigné n'impose pas l'échelle")
    func pruHorsPlageIgnoré() {
        // A security bought at €250, trading today around €40.
        let domaine = ChartYDomain.compute(values: [39, 40, 41],
                                           references: [250],
                                           padding: 0.08,
                                           clampToZero: true)

        #expect(!domaine.contains(250))
        // The amplitude stays that of the curve (€2) plus a modest padding,
        // not the €211 the cost basis would impose.
        #expect(domaine.upperBound - domaine.lowerBound < 3)
        #expect(domaine.contains(39))
        #expect(domaine.contains(41))
    }

    @Test("Un PRU proche élargit bien le domaine")
    func pruProcheRetenu() {
        // Here the cost basis is within range: it must stay visible, that's its point
        // (a readable break-even threshold under the curve).
        let domaine = ChartYDomain.compute(values: [39, 40, 41],
                                           references: [38.5],
                                           padding: 0.08,
                                           clampToZero: true)

        #expect(domaine.contains(38.5))
        #expect(domaine.lowerBound < 38.5)
    }

    @Test("Le padding suit l'amplitude, pas la valeur absolue")
    func paddingProportionnelÀLAmplitude() {
        // A regression of the second defect: a padding of `lo * 0.92 ... hi * 1.08`
        // on a €39–41 series gave 35.9–44.3 — a padding worth four
        // times the real amplitude, which crushed the curve all by itself.
        let domaine = ChartYDomain.compute(values: [39, 40, 41], padding: 0.08)

        let amplitudeSérie = 2.0
        let amplitudeDomaine = domaine.upperBound - domaine.lowerBound
        #expect(amplitudeDomaine < amplitudeSérie * 1.5)
        #expect(domaine.lowerBound > 38)
        #expect(domaine.upperBound < 42)
    }

    @Test("Changer de plage rééquilibre l'échelle")
    func échelleSuitLaPlage() {
        // The same security, two windows: the short window must get a
        // tight scale, otherwise its own movement stays invisible.
        let longue = ChartYDomain.compute(values: [10, 55, 40, 41, 39, 40])
        let courte = ChartYDomain.compute(values: [41, 39, 40])

        #expect(courte.upperBound - courte.lowerBound
                < (longue.upperBound - longue.lowerBound) / 10)
    }

    // MARK: - Degenerate series

    @Test("Une série parfaitement plate garde une bande lisible")
    func sériePlate() {
        let domaine = ChartYDomain.compute(values: [100, 100, 100])

        #expect(domaine.lowerBound < 100)
        #expect(domaine.upperBound > 100)
        #expect(domaine.upperBound - domaine.lowerBound > 0)
    }

    @Test("Une série vide retombe sur les repères, puis sur le repli")
    func sérieVide() {
        // Without a series, the reference point becomes the only information available and
        // so regains the right to set the scale.
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
        // A safeguard: `ClosedRange` requires lower <= upper, a clamp to zero on
        // a series that's itself at zero could otherwise invert the range.
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
        // Amplitude 10 (40→50), tolerance 0.6 ⇒ a reference point is kept up to
        // 6 units below the curve, no further.
        let retenu = ChartYDomain.compute(values: [40, 50], references: [35],
                                          referenceTolerance: 0.6)
        #expect(retenu.contains(35))

        let écarté = ChartYDomain.compute(values: [40, 50], references: [30],
                                          referenceTolerance: 0.6)
        #expect(!écarté.contains(30))
    }
}
