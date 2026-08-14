import Foundation

// MARK: - Fusion des deux extractions d'un relevé
//
// Moteur PUR (aucun accès réseau, disque, IA ni SwiftUI) — même doctrine que
// `InvestmentStatementExtractor` et `PortfolioEvolutionBuilder` : testable hors
// Xcode par `run_statement_extractor_tests.sh`.
//
// ─── Pourquoi ce fichier existe ────────────────────────────────────────────
//
// L'ancienne fusion vivait dans `InvestmentPDFParser` et tenait en une règle :
// « le déterministe fait autorité sur les ISIN qu'il a reconnus, l'IA complète
// le reste ». Trois défauts mesurés sur un relevé réel de 34 opérations :
//
//   1. **La quantité restait à 1 partout.** Sur un relevé en TABLEAU, le
//      libellé « Quantité » n'apparaît qu'UNE fois, dans l'en-tête de colonne —
//      pas sur chacune des 34 lignes de données. L'ancrage par ISIN, qui
//      cherche un nombre APRÈS un libellé, ne peut donc pas la lire, et
//      `valuation(...)` retombe sur « quantité inconnue ⇒ 1 × montant ». Le
//      déterministe ABAISSAIT alors sa propre confiance (0,60) pour le
//      signaler… mais gardait quand même l'autorité, y compris quand l'IA,
//      elle, avait correctement lu la colonne.
//   2. **Le compte gonflait** (36-37 lignes pour 34 opérations réelles) : une
//      opération vue par l'IA sans ISIN — ou avec un ISIN mal recopié — était
//      ajoutée SANS AUCUNE vérification de doublon, `knownISINs` ne pouvant
//      par construction jamais contenir la chaîne vide.
//   3. **L'utilisateur voyait « aucune IA utilisée »** : chaque ligne rendue
//      venait du déterministe, note comprise, alors que le modèle avait bel et
//      bien tourné et produit de meilleurs nombres.
//
// La règle devient donc : le déterministe reste l'ossature (il ne se trompe
// jamais d'ISIN ni de date), mais **il cède ses nombres dès qu'il admet lui-même
// le doute**, et une ligne n'est ajoutée que si elle ne correspond à aucune
// opération déjà connue.

/// Vue minimale d'une opération, indépendante du modèle qui la porte.
///
/// ⚠️ Un protocole, et pas le type concret : la fusion doit s'appliquer aussi
/// bien aux `ExtractedStatementOrder` (moteur pur, date en chaîne) qu'aux
/// `PDFExtractedOrder` (modèle d'UI, date en `Date`, identité et sélection).
/// Écrire la règle deux fois, une par modèle, c'est la classe de bug que ce
/// dépôt paie déjà ailleurs (, quatre calculs d'enveloppes divergents).
protocol StatementOrderFields {
    var orderType: String { get }
    var assetName: String { get }
    var isin: String { get }
    var ticker: String { get set }
    var quantity: Double { get set }
    var unitPrice: Double { get set }
    var fees: Double { get set }
    var confidence: Double { get set }
    var notes: String? { get set }
    /// Date d'exécution normalisée en yyyy-MM-dd.
    var isoDay: String { get }
}

extension ExtractedStatementOrder: StatementOrderFields {
    var isoDay: String { executedAt }
}

enum StatementReconciler {

    /// En dessous de cette confiance, une opération déterministe a DÉDUIT au
    /// moins un de ses nombres au lieu de le lire (`InvestmentStatementExtractor.
    /// parseBlock` : -0,15 quand la quantité manque, -0,1 quand la valorisation
    /// est déduite). Choisi pour qu'une opération parfaitement lue (0,85) ne
    /// soit jamais réécrite, et qu'une opération douteuse le soit toujours.
    static let uncertainConfidence = 0.75

    /// Marque portée par une opération dont les nombres viennent du modèle.
    /// Visible dans la fiche de l'ordre après import — sans elle, rien ne
    /// distingue après coup une lecture renforcée d'une lecture de premier jet.
    static let textTag = "Quantité/prix relus par l'IA"
    static let imageTag = "Quantité/prix relus sur l'image (tableau)"

    // MARK: - Fusion complète

    /// Ossature déterministe renforcée par l'IA, PLUS les opérations que seule
    /// l'IA a vues (formats en prose, lignes sans ISIN — que l'ancrage ne peut
    /// pas voir par construction).
    static func reconcile<T: StatementOrderFields>(ai: [T], deterministic: [T],
                                                   tag: String = textTag) -> [T] {
        let candidates = dedupe(ai)
        guard !deterministic.isEmpty else { return candidates }

        var consumed = Set<Int>()
        var result = deterministic
        for index in result.indices {
            guard let match = matchIndex(for: result[index], in: candidates, excluding: consumed)
            else { continue }
            consumed.insert(match)
            result[index] = merging(result[index], with: candidates[match], tag: tag)
        }
        // ⚠️ Une opération de l'IA n'est ajoutée que si elle ne correspond à
        // AUCUNE opération déjà retenue — c'est ce qui manquait : une ligne
        // sans ISIN passait systématiquement, d'où un relevé de 34 opérations
        // qui en rendait 36 ou 37, et un compte différent à chaque analyse
        // puisque le modèle ne rate pas les mêmes lignes d'une fois sur l'autre.
        for (index, candidate) in candidates.enumerated() where !consumed.contains(index) {
            result.append(candidate)
        }
        return result
    }

    // MARK: - Fusion d'une paire

    /// Applique une opération candidate sur une opération de base.
    ///
    /// Le ticker est TOUJOURS repris quand il manque (le déterministe ne le
    /// cherche pas : il n'a pas de forme normalisée). Les NOMBRES ne sont repris
    /// que si la base admet le doute — la date, le nom, le type et l'ISIN
    /// restent à la base, qui ne s'y trompe pas.
    private static func merging<T: StatementOrderFields>(_ base: T, with candidate: T,
                                                          tag: String) -> T {
        var merged = base
        if merged.ticker.isEmpty { merged.ticker = candidate.ticker }
        guard base.confidence < uncertainConfidence, candidate.quantity > 0 else { return merged }

        // ⚠️ Le MONTANT lu par le déterministe prime sur le prix rendu par le
        // modèle quand les deux se contredisent. Un montant est extrait par un
        // motif qui exige des centimes ou une devise collée (cf.
        // `signedAmount`) : c'est un nombre réellement présent dans le
        // document. Un modèle, lui, recopie volontiers le TOTAL dans le champ
        // « prix unitaire » — sans ce garde-fou, une opération de 982,40 €
        // devenait 4 × 982,40 = 3 929,60 €.
        let gross = abs(base.quantity * base.unitPrice)
        var price: Double? = candidate.unitPrice > 0 ? candidate.unitPrice : nil
        if gross > 0, let proposed = price,
           abs(proposed * candidate.quantity - gross) > max(0.05, gross * 0.05) {
            price = nil   // le prix sera redéduit du montant réellement lu
        }

        let valued = InvestmentStatementExtractor.valuation(
            orderType: base.orderType, quantity: candidate.quantity,
            unitPrice: price, gross: gross > 0 ? gross : nil)

        merged.quantity = valued.quantity
        merged.unitPrice = valued.unitPrice

        // ⚠️ Un modèle confond parfois « Commission » avec « Montant brut »
        // dans un footer à plusieurs colonnes monétaires adjacentes (Montant
        // brut | Commission | Frais | Montant net) — constaté sur un cas réel
        // où les frais rendus valaient EXACTEMENT le montant brut, doublant
        // le total affiché (`totalCost = quantité × prix + frais`). Une
        // commission plausible reste une PETITE fraction du montant de
        // l'opération ; au-delà, c'est probablement une autre colonne qui a
        // été lue. Même doctrine que le garde-fou sur `price` ci-dessus.
        let trueGross = abs(valued.quantity * valued.unitPrice)
        let feesArePlausible = trueGross == 0 || candidate.fees < trueGross * 0.5
        if merged.fees == 0, candidate.fees > 0, feesArePlausible {
            merged.fees = candidate.fees
        }
        merged.confidence = max(base.confidence, uncertainConfidence)
        merged.notes = appending(tag, to: base.notes)
        return merged
    }

    private static func appending(_ tag: String, to notes: String?) -> String {
        guard let notes, !notes.isEmpty else { return tag }
        guard !notes.contains(tag) else { return notes }
        return notes + " · " + tag
    }

    // MARK: - « Est-ce la même opération ? »

    /// Une seule notion d'identité, partagée par le renforcement ET la
    /// déduplication : deux réponses différentes à cette question feraient
    /// corriger une ligne tout en la rajoutant ensuite en double.
    static func isSameOperation<T: StatementOrderFields>(_ a: T, _ b: T) -> Bool {
        let isinA = a.isin.uppercased(), isinB = b.isin.uppercased()
        if !isinA.isEmpty, !isinB.isEmpty {
            // ISIN identique : le jour OU le montant suffit à confirmer. Le
            // « ou » compte — certains relevés datent l'opération, le modèle
            // rend parfois la date de règlement.
            guard isinA == isinB else { return false }
            return a.isoDay == b.isoDay || closeAmounts(a, b)
        }
        // Sans ISIN comparable, le jour devient obligatoire : c'est le seul
        // champ assez discriminant pour ne pas fusionner deux opérations
        // distinctes du même titre.
        guard a.isoDay == b.isoDay, !a.isoDay.isEmpty else { return false }
        return closeAmounts(a, b) || similarNames(a.assetName, b.assetName)
    }

    private static func closeAmounts<T: StatementOrderFields>(_ a: T, _ b: T) -> Bool {
        let totalA = abs(a.quantity * a.unitPrice)
        let totalB = abs(b.quantity * b.unitPrice)
        guard totalA > 0, totalB > 0 else { return false }
        return abs(totalA - totalB) <= max(0.02, max(totalA, totalB) * 0.01)
    }

    /// Noms « assez proches » : un relevé écrit « AM.PEA EM.ES.T.ACC » là où un
    /// modèle rend « Amundi PEA Emerging Markets ». On ne cherche donc pas
    /// l'égalité, mais l'inclusion d'une forme normalisée dans l'autre.
    private static func similarNames(_ a: String, _ b: String) -> Bool {
        let normalizedA = normalize(a), normalizedB = normalize(b)
        guard normalizedA.count >= 5, normalizedB.count >= 5 else { return false }
        return normalizedA.contains(normalizedB) || normalizedB.contains(normalizedA)
    }

    private static func normalize(_ name: String) -> String {
        String(name.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    private static func matchIndex<T: StatementOrderFields>(for order: T, in pool: [T],
                                                            excluding consumed: Set<Int>) -> Int? {
        // Appariement UN POUR UN : deux achats du même titre le même jour sont
        // deux opérations réelles, chacune ayant son ancre ISIN côté
        // déterministe. Sans exclusion des candidats déjà consommés, elles
        // pointeraient toutes les deux vers la même ligne de l'IA — la seconde
        // resterait non corrigée et la ligne restante repartirait en doublon.
        //
        // ⚠️ Deux passes, et l'ordre compte. Quand plusieurs candidats
        // conviennent (même titre, même jour, deux montants différents), celui
        // dont le MONTANT coïncide est le bon ; se contenter du premier venu
        // apparierait les deux opérations à l'envers et échangerait leurs
        // quantités.
        if let strong = pool.indices.first(where: {
            !consumed.contains($0) && isSameOperation(order, pool[$0]) && closeAmounts(order, pool[$0])
        }) { return strong }
        return pool.indices.first {
            !consumed.contains($0) && isSameOperation(order, pool[$0])
        }
    }

    // MARK: - Déduplication interne

    /// Retire les répétitions d'une même source. Un modèle relance parfois la
    /// même opération à la fin d'une longue liste, et deux blocs de texte
    /// consécutifs peuvent se recouvrir.
    ///
    /// ⚠️ Prédicat STRICT, pas `isSameOperation`. Ce dernier est fait pour
    /// rapprocher deux LECTURES de la même opération, donc volontairement
    /// tolérant (il accepte un jour identique sans montant comparable). Appliqué
    /// à une seule et même source, il fusionnerait deux achats réels du même
    /// titre passés le même jour à des cours différents.
    static func dedupe<T: StatementOrderFields>(_ orders: [T]) -> [T] {
        var kept: [T] = []
        for order in orders where !kept.contains(where: { isRepetition($0, order) }) {
            kept.append(order)
        }
        return kept
    }

    private static func isRepetition<T: StatementOrderFields>(_ a: T, _ b: T) -> Bool {
        guard a.isoDay == b.isoDay, a.orderType == b.orderType else { return false }
        let sameTitle = (!a.isin.isEmpty && a.isin.uppercased() == b.isin.uppercased())
            || similarNames(a.assetName, b.assetName)
        guard sameTitle else { return false }
        // Deux montants nuls des deux côtés : rien ne les distingue non plus.
        let totalA = abs(a.quantity * a.unitPrice), totalB = abs(b.quantity * b.unitPrice)
        return closeAmounts(a, b) || (totalA == 0 && totalB == 0)
    }
}
