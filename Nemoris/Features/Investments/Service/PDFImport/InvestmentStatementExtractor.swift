import Foundation

// MARK: - Extraction déterministe d'opérations depuis un relevé / une capture
//
// Moteur PUR (aucun accès réseau, disque, IA ni SwiftUI) — même doctrine que
// `PortfolioEvolutionBuilder` et `MerchantQueryPlanner` : testable hors Xcode.
//
// ─── Pourquoi ce moteur existe ─────────────────────────────────────────────
//
// L'import de relevés reposait à 100 % sur Apple Foundation Models. Trois
// conséquences, toutes constatées :
//   1. Sur un appareil sans Apple Intelligence (iOS 18-25, Mac non éligible,
//      fonctionnalité désactivée), l'import ne pouvait RIEN extraire — alors
//      qu'un relevé bancaire est un format tabulaire très régulier.
//   2. Quand le modèle échouait (contexte dépassé, JSON malformé), l'erreur
//      était avalée et l'écran affichait « Rien à importer », indiscernable
//      d'un document réellement vide.
//   3. Aucun garde-fou : une extraction 100 % probabiliste sans filet.
//
// Ce moteur n'essaie PAS de battre l'IA sur les formats libres. Il couvre le
// cas dominant — une ligne d'opération identifiée par son ISIN — et sert de
// repli systématique quand l'IA n'a rien produit.
//
// ─── Ancrage sur l'ISIN ────────────────────────────────────────────────────
//
// L'ISIN est le seul identifiant réellement fiable dans un relevé : format
// normalisé (ISO 6166), présent sur tous les avis d'opéré et la plupart des
// écrans de courtiers. On découpe donc le texte en blocs autour de chaque ISIN
// trouvé, puis on cherche les autres champs DANS ce bloc. Un texte OCR d'app
// mobile arrive en colonne (un champ par ligne), un PDF arrive en tableau :
// le découpage par ISIN absorbe les deux.

/// Une opération reconnue sans IA. Volontairement distincte de
/// `PDFExtractedOrder` (qui porte de l'état d'UI) : ce moteur reste pur.
struct ExtractedStatementOrder: Equatable, Codable, Hashable, Sendable {
    var orderType: String        // "BUY" | "SELL" | "DIV"
    var assetName: String
    var isin: String
    /// Symbole boursier court. Le SEUL champ que l'ancrage par ISIN ne cherche
    /// pas (il n'a pas de forme normalisée) : il est rempli par la
    /// réconciliation, depuis l'IA ou depuis un format structuré qui le nomme.
    /// Valeur par défaut pour que les sites de construction du moteur
    /// déterministe restent inchangés.
    var ticker: String = ""
    var quantity: Double
    var unitPrice: Double
    var fees: Double
    /// Date au format yyyy-MM-dd (chaîne : le moteur ne dépend pas de Calendar).
    var executedAt: String
    var currency: String
    var notes: String?
    /// Confiance : dégradée quand un champ a dû être déduit plutôt que lu.
    var confidence: Double
}

enum InvestmentStatementExtractor {

    // MARK: - Point d'entrée

    /// Extrait toutes les opérations reconnaissables d'un texte brut.
    static func extractOrders(from text: String) -> [ExtractedStatementOrder] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let anchors = isinAnchors(in: lines)
        guard !anchors.isEmpty else { return [] }

        var results: [ExtractedStatementOrder] = []
        for (index, anchor) in anchors.enumerated() {
            // ⚠️ Deux fenêtres, bornées par les ancres VOISINES et jamais l'une
            // par l'autre — c'est ce qui empêche un champ de remonter du bloc
            // précédent ou suivant, sans pour autant l'enfermer dans un nombre
            // de lignes arbitraire :
            //
            //   • APRÈS l'ISIN, jusqu'à l'ISIN suivant : le cas dominant pour
            //     un avis d'opéré (« Quantité exécutée : 2,000 » vient après
            //     le code).
            //   • AVANT l'ISIN, depuis l'ISIN précédent : nécessaire pour un
            //     vrai TABLEAU (pas un texte en colonne). Ici l'ISIN est la
            //     2ᵉ sous-ligne de sa cellule (« Code ISIN : … » sous le nom
            //     du titre), alors qu'une cellule voisine de la MÊME ligne
            //     visuelle — la quantité, alignée avec la date — se retrouve
            //     AVANT lui une fois le tableau aplati en texte par PDFKit.
            //     Bug réel : « 4 » (quantité) invisible parce que la seule
            //     fenêtre alors cherchée était celle d'APRÈS l'ISIN.
            //
            // Le libellé (« Quantité », « Cours », « Frais ») protège contre
            // les faux positifs sur la fenêtre AVANT — un en-tête de banque ne
            // contient jamais ces mots — donc l'élargir ne coûte rien en
            // précision, contrairement à un nombre de lignes fixe qui peut
            // couper le tableau au mauvais endroit selon sa mise en page.
            let fieldsUpper = index == anchors.count - 1
                ? lines.count - 1
                : min(lines.count - 1, anchors[index + 1].line - 1)
            guard anchor.line <= fieldsUpper else { continue }
            let fields = Array(lines[anchor.line...fieldsUpper])

            let beforeLower = index == 0 ? 0 : anchors[index - 1].line + 1
            let beforeWindow = beforeLower < anchor.line
                ? Array(lines[beforeLower..<anchor.line])
                : []

            if let order = parseBlock(fields: fields, nameWindow: beforeWindow, isin: anchor.isin) {
                results.append(order)
            }
        }
        return results
    }

    // MARK: - Ancres ISIN

    private struct ISINAnchor {
        let line: Int
        let isin: String
    }

    /// Un ISIN : 2 lettres pays + 9 alphanumériques + 1 chiffre de contrôle.
    /// On valide la clé de Luhn pour écarter les faux positifs (une référence
    /// interne de banque peut avoir la même forme).
    private static let isinPattern = try? NSRegularExpression(
        pattern: "\\b([A-Z]{2}[A-Z0-9]{9}[0-9])\\b")

    private static func isinAnchors(in lines: [String]) -> [ISINAnchor] {
        guard let regex = isinPattern else { return [] }
        var anchors: [ISINAnchor] = []
        for (index, line) in lines.enumerated() {
            let upper = line.uppercased()
            let range = NSRange(upper.startIndex..., in: upper)
            regex.enumerateMatches(in: upper, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: upper) else { return }
                let candidate = String(upper[r])
                guard isValidISIN(candidate) else { return }
                anchors.append(ISINAnchor(line: index, isin: candidate))
            }
        }
        return anchors
    }

    /// Validation ISO 6166 : lettres converties en nombres (A=10 … Z=35), puis
    /// Luhn sur la chaîne de chiffres obtenue.
    static func isValidISIN(_ isin: String) -> Bool {
        guard isin.count == 12 else { return false }
        var digits = ""
        for ch in isin.uppercased() {
            if let d = ch.wholeNumberValue, ch.isNumber {
                digits += String(d)
            } else if ch.isLetter, let ascii = ch.asciiValue {
                digits += String(Int(ascii - 65) + 10)
            } else {
                return false
            }
        }
        var sum = 0
        var double = true   // on double en partant de la droite, hors dernier chiffre
        for ch in digits.dropLast().reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if double {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
            double.toggle()
        }
        guard let check = digits.last?.wholeNumberValue else { return false }
        return (10 - (sum % 10)) % 10 == check
    }

    // MARK: - Parsing d'un bloc

    private static func parseBlock(fields: [String], nameWindow: [String], isin: String) -> ExtractedStatementOrder? {
        let joined = fields.joined(separator: "\n")
        let upper = joined.uppercased()
        // Repli sur le nom quand la nature ou la date sont AU-DESSUS du code
        // (certains formats titrent « Achat — 15/03/2024 » avant l'ISIN).
        let fallback = nameWindow.joined(separator: "\n")

        guard let orderType = detectOrderType(in: upper) ?? detectOrderType(in: fallback.uppercased()) else { return nil }
        guard let date = firstDate(in: joined) ?? firstDate(in: fallback) else { return nil }

        // ⚠️ Repli AVANT l'ISIN pour chaque champ numérique — mais restreint au
        // PRÉAMBULE de CE bloc, pas tout `nameWindow`.
        //
        // Sur un vrai tableau, l'en-tête de colonne (« Quantité ») et sa
        // valeur (« 4 ») sont légitimement avant l'ISIN (bug réel corrigé
        // ici). Mais sur une capture à plusieurs opérations consécutives,
        // `nameWindow` contient AUSSI la fin des champs du bloc PRÉCÉDENT
        // (sa propre quantité, son propre cours) — et un dividende sans cours
        // affiché happait alors le cours du titre acheté juste avant lui.
        //
        // La ligne de nom la plus proche de l'ISIN (déjà calculée par
        // `assetName` ci-dessous, ici anticipée) marque la frontière : tout ce
        // qui la précède appartient structurellement au bloc d'AVANT.
        let preambleStart = nameLineIndex(in: nameWindow) ?? 0
        let preamble = preambleStart < nameWindow.count
            ? Array(nameWindow[preambleStart...]).joined(separator: "\n")
            : ""

        // `firstNumberNearLabel`, pas `firstNumber`, sur ce repli : dans un
        // tableau, l'EN-TÊTE de colonne et sa VALEUR sont sur deux lignes
        // DIFFÉRENTES (ligne d'en-tête, puis ligne de données) — `firstNumber`
        // exige la même ligne. La variante tolérante cherche sur les quelques
        // lignes suivant le libellé, après avoir retiré les dates reconnues :
        // sans ce retrait, le jour d'une date sur la ligne de données
        // (« 13/01/2025 4 … ») serait pris pour la quantité qui le suit.
        // ⚠️ La variante tolérante s'applique aux DEUX fenêtres, pas seulement
        // au préambule. Dans un tableau, l'en-tête de colonne et sa valeur sont
        // sur deux lignes distinctes des deux côtés de l'ancre — les frais de
        // l'avis d'opéré BoursoBank (« Commission … » puis « 1,11 EUR … »)
        // tombaient APRÈS le code ISIN, donc dans une fenêtre où seule la
        // recherche stricte, même-ligne, était tentée : la commission n'était
        // jamais lue.
        let quantity = firstNumber(in: joined, labels: quantityLabels)
            ?? firstNumberNearLabel(in: joined, labels: quantityLabels)
            ?? firstNumberNearLabel(in: preamble, labels: quantityLabels)
        let priceFromLabel = firstNumber(in: joined, labels: priceLabels)
            ?? firstNumberNearLabel(in: joined, labels: priceLabels)
            ?? firstNumberNearLabel(in: preamble, labels: priceLabels)
        var fees = firstNumber(in: joined, labels: feeLabels)
            ?? firstNumberNearLabel(in: joined, labels: feeLabels)
            ?? firstNumberNearLabel(in: preamble, labels: feeLabels) ?? 0

        // ⚠️ Le montant LIBELLÉ prime sur « le premier montant du bloc ».
        //
        // Bug réel (avis d'opéré BoursoBank) : le bloc s'ouvre sur « Code ISIN
        // … Cours exécuté : 55,62 EUR », donc `signedAmount` retenait le COURS
        // comme montant de l'opération — le vrai total, « Montant transaction
        // brut 222,48 EUR », arrivant plus bas. Conséquence en cascade : la
        // quantité ne pouvait plus se déduire (55,62 ÷ 55,62 = 1) et l'ordre
        // s'importait en « 1 × 55,62 € » au lieu de « 4 × 55,62 € ».
        //
        // Un relevé qui donne un total le LIBELLE toujours ; le repli non
        // libellé reste pour les captures d'app, où le montant est seul sur sa
        // ligne sans en-tête.
        let gross = firstNumber(in: joined, labels: totalLabels)
            ?? firstNumberNearLabel(in: joined, labels: totalLabels)
            ?? firstNumber(in: preamble, labels: totalLabels)
            ?? firstNumberNearLabel(in: preamble, labels: totalLabels)
            ?? signedAmount(in: joined) ?? signedAmount(in: preamble)

        // ⚠️ Frais IMPLAUSIBLES rejetés avant tout repli. `firstNumberNearLabel`
        // n'a aucune notion de COLONNE : sur la ligne de VALEURS d'un footer à
        // 4 colonnes (« Montant brut | Commission | Frais | Montant net »),
        // elle rend le PREMIER nombre de la ligne — qui est le montant brut,
        // pas la commission, dès que « Commission » n'est pas la 1ʳᵉ colonne.
        // Bug réel mesuré : les frais rendus valaient EXACTEMENT le montant
        // brut, doublant le total affiché (`quantité × prix + frais`). Une
        // commission plausible reste une PETITE fraction du montant de
        // l'opération ; un nombre trouvé « pour les frais » qui se rapproche
        // du brut n'est pas une lecture, c'est une confusion de colonne — on
        // le traite comme si rien n'avait été trouvé, pour laisser la place
        // au repli par soustraction ci-dessous.
        if let grossValue = gross, grossValue > 0, fees >= grossValue * 0.5 {
            fees = 0
        }

        // ⚠️ Repli par SOUSTRACTION quand aucun libellé de frais direct n'a
        // payé (« Commission »/« Frais » introuvables, ou rejetés ci-dessus
        // comme implausibles). Un footer à 4 colonnes (Montant brut |
        // Commission | Frais (♦) | Montant net au débit) regroupe souvent ses
        // 4 EN-TÊTES d'un bloc avant ses 4 VALEURS une fois le tableau aplati
        // par PDFKit — la valeur de « Commission » peut alors se retrouver à
        // plus de `lineSpan` lignes de son libellé, ou dans la mauvaise
        // colonne d'une ligne de valeurs groupées. Plutôt que de complexifier
        // la recherche par position, on déduit les frais de la différence
        // entre le montant NET et le montant BRUT — deux totaux que le
        // document donne presque toujours, chacun bien identifié par son
        // propre libellé complet en fin de ligne, sans dépendre de la
        // position d'une cellule isolée dans une mise en page qui varie d'un
        // courtier à l'autre. `abs(...)` marche dans les deux sens : un achat
        // paie plus que le brut (net > brut), une vente reçoit moins (net <
        // brut).
        if fees == 0, let grossValue = gross {
            // ⚠️ `lastNumberNearLabel`, pas `firstNumberNearLabel` : « Montant
            // net » est la DERNIÈRE colonne du footer, alors que la variante
            // « first » — pensée pour « Montant brut », en 1ʳᵉ colonne —
            // renverrait ENCORE le montant brut sur la ligne de valeurs
            // groupées, rendant `net == grossValue` et la soustraction nulle.
            let net = lastNumber(in: joined, labels: netLabels)
                ?? lastNumberNearLabel(in: joined, labels: netLabels)
                ?? lastNumber(in: preamble, labels: netLabels)
                ?? lastNumberNearLabel(in: preamble, labels: netLabels)
            if let net {
                let derived = abs(net - grossValue)
                // Garde-fou : des frais ne dépassent normalement pas le
                // montant brut lui-même — au-delà, les deux nombres trouvés
                // ne décrivent probablement pas la même opération (deux
                // lignes voisines d'un relevé à plusieurs opérations).
                if derived > 0.001, derived < grossValue {
                    fees = derived
                }
            }
        }

        var confidence = 0.85
        if priceFromLabel == nil { confidence -= 0.05 }

        let valuation = valuation(orderType: orderType,
                                  quantity: quantity,
                                  unitPrice: priceFromLabel,
                                  gross: gross)

        // ⚠️ Une quantité DÉRIVÉE de `montant ÷ cours`, quand les DEUX sont
        // libellés dans le document, n'est pas une supposition : c'est une
        // vérification. `4 × 55,62 = 222,48` reproduit exactement le montant
        // brut imprimé sur l'avis. Elle reste donc AU-DESSUS du seuil de
        // relecture (`StatementReconciler.uncertainConfidence`) — sans quoi un
        // modèle qui répond « quantité 1 » écrase une valeur arithmétiquement
        // exacte, ce qui était le cas et annulait tout le bénéfice de la
        // déduction.
        //
        // Sans ces deux ancrages, en revanche, la quantité vaut « 1 » faute de
        // mieux : c'est une vraie inconnue, et l'IA doit pouvoir la corriger.
        let quantityIsVerified = quantity == nil
            && valuation.quantity > 0 && gross != nil && priceFromLabel != nil
        if quantityIsVerified {
            confidence -= 0.05
        } else if quantity == nil {
            confidence -= 0.15
            if valuation.deduced { confidence -= 0.1 }
        } else if valuation.deduced {
            confidence -= 0.1
        }
        let unitPrice = valuation.unitPrice

        let name = assetName(in: nameWindow, fallbackAfter: fields)
        if name.isEmpty { confidence -= 0.2 }

        return ExtractedStatementOrder(
            orderType: orderType,
            assetName: name.isEmpty ? isin : name,
            isin: isin,
            quantity: valuation.quantity,
            unitPrice: unitPrice,
            fees: fees,
            executedAt: date,
            currency: detectCurrency(in: upper),
            // Note NEUTRE plutôt que « sans IA » : l'opération peut être
            // renforcée juste après par `StatementReconciler`, et la note
            // aurait alors affirmé le contraire de ce qui s'est passé.
            notes: "Extraction automatique (ancrage ISIN)",
            confidence: max(0.2, min(1, confidence))
        )
    }

    // MARK: - Valorisation d'une opération

    /// Quantité et prix unitaire cohérents, de sorte que
    /// `quantité × prix` soit TOUJOURS le montant réel de l'opération.
    ///
    /// ⚠️ Un DIVIDENDE n'a ni quantité ni cours d'exécution : sa valeur EST le
    /// montant crédité. Le forcer dans le moule « quantité × prix » donnait un
    /// prix nul, donc un dividende à **0 €** — constaté sur un avis d'opéré
    /// réel. Même défaut pour un achat dont le document ne nomme pas la
    /// quantité : elle tombait à 0, et le total avec elle.
    ///
    /// Règle : quand le document donne un MONTANT, l'opération ne vaut jamais
    /// zéro. À quantité inconnue, on retient 1 et le montant devient le prix
    /// unitaire — la valeur est juste, et c'est ce qui compte pour le
    /// portefeuille. Quand la quantité est connue (100 titres pour 34,53 € de
    /// coupon), le prix unitaire s'en déduit et le produit reste exact.
    ///
    /// Moteur PUR, partagé avec le chemin IA (`InvestmentPDFParser.convert`) :
    /// une extraction déterministe et une extraction par modèle ne doivent pas
    /// valoriser différemment la même opération.
    static func valuation(orderType: String,
                          quantity: Double?,
                          unitPrice: Double?,
                          gross: Double?) -> (quantity: Double, unitPrice: Double, deduced: Bool) {
        let amount = gross.map(abs) ?? 0
        let knownQuantity = (quantity ?? 0) > 0 ? quantity! : nil
        let knownPrice = (unitPrice ?? 0) > 0 ? unitPrice! : nil

        // Cas nominal : les deux sont lus dans le document.
        if let knownQuantity, let knownPrice {
            return (knownQuantity, knownPrice, false)
        }
        // Prix absent mais montant connu : on le déduit.
        if let knownQuantity, amount > 0 {
            return (knownQuantity, amount / knownQuantity, true)
        }
        // ⚠️ Quantité absente, mais PRIX et MONTANT connus : `quantité =
        // montant ÷ prix`. C'est de l'arithmétique, pas une heuristique de
        // mise en page — donc valable quel que soit le courtier, là où aucune
        // fenêtre de recherche autour d'un libellé ne peut couvrir toutes les
        // dispositions possibles.
        //
        // Cas réel (avis d'opéré BoursoBank) : la quantité « 4 » se trouve
        // TROIS lignes sous son en-tête de colonne, une fois le tableau aplati
        // par PDFKit — introuvable par libellé. Mais « Montant transaction
        // brut 222,48 EUR » et « Cours exécuté : 55,62 EUR » sont tous les
        // deux libellés, et leur quotient vaut exactement 4.
        if let knownPrice, amount > 0 {
            let derived = amount / knownPrice
            // Garde-fou : un rapport absurde signale qu'on a comparé deux
            // grandeurs sans rapport (un montant de frais avec un cours, par
            // exemple) — mieux vaut alors ne rien déduire.
            if derived.isFinite, derived > 0, derived < 1_000_000 {
                return (snappedToWhole(derived), knownPrice, true)
            }
        }
        // Quantité absente et aucun montant : le prix devient celui d'une
        // « unité ».
        if let knownPrice, knownQuantity == nil {
            return (1, knownPrice, true)
        }
        if amount > 0 {
            return (1, amount, true)
        }
        // Rien d'exploitable : on ne fabrique pas un montant.
        return (knownQuantity ?? 0, knownPrice ?? 0, false)
    }

    /// Arrondit une quantité déduite d'une division quand elle frôle un entier.
    ///
    /// ⚠️ Tolérance très serrée, et volontairement : les parts d'ETF et de fonds
    /// se détiennent en fractions (0,347 part), donc on ne « corrige » que le
    /// résidu d'arrondi d'une division exacte (222,48 ÷ 55,62), jamais une
    /// quantité réellement fractionnaire.
    private static func snappedToWhole(_ value: Double) -> Double {
        let rounded = value.rounded()
        guard rounded >= 1, abs(value - rounded) < 0.001 else { return value }
        return rounded
    }

    // MARK: - Champs

    /// Mots-clés d'opération, du plus spécifique au plus général : « ACHAT
    /// COMPTANT » et « SOUSCRIPTION » avant le simple « ACH », sinon un libellé
    /// contenant « ACHAT » dans une phrase parasite déclencherait un faux BUY.
    private static let buyKeywords  = ["ACHAT", "ACQUISITION", "SOUSCRIPTION", "BUY", "KAUF", "COMPRA", "ACH "]
    private static let sellKeywords = ["VENTE", "CESSION", "RACHAT", "SELL", "VERKAUF", "VENTA", "VTE "]
    private static let divKeywords  = ["COUPON", "DIVIDENDE", "DIVIDEND", "DISTRIBUTION", "DÉTACHEMENT", "DETACHEMENT"]

    static func detectOrderType(in upperText: String) -> String? {
        // Dividende testé en premier : « COUPONS » peut cohabiter avec le nom
        // d'un titre obligataire contenant « ACHAT » n'a pas de sens, mais un
        // relevé mixte liste souvent achats ET coupons — c'est le bloc qui
        // tranche, et le mot dividende y est le plus discriminant.
        if divKeywords.contains(where: { upperText.contains($0) })  { return "DIV" }
        if sellKeywords.contains(where: { upperText.contains($0) }) { return "SELL" }
        if buyKeywords.contains(where: { upperText.contains($0) })  { return "BUY" }
        return nil
    }

    private static func detectCurrency(in upperText: String) -> String {
        if upperText.contains("USD") || upperText.contains("$") { return "USD" }
        if upperText.contains("GBP") || upperText.contains("£") { return "GBP" }
        if upperText.contains("CHF") { return "CHF" }
        return "EUR"
    }

    /// Libellés des champs, FR et EN — un relevé Interactive Brokers ou Trade
    /// Republic écrit « Quantity » / « Price », pas « Quantité » / « Cours ».
    private static let quantityLabels = [
        "QUANTITÉ EXÉCUTÉE", "QUANTITE EXECUTEE", "QUANTITÉ", "QUANTITE",
        "QTÉ", "QTE", "NOMBRE DE PARTS", "NOMBRE", "QUANTITY", "SHARES", "UNITS"
    ]
    /// ⚠️ « Cours exécuté » PRIME sur « Cours demandé » : un ordre à cours
    /// limité peut demander un prix et s'exécuter à un autre. Le label générique
    /// « COURS » matcherait « Cours demandé », qui apparaît souvent AVANT
    /// « Cours exécuté » dans un avis d'opéré — donc en premier sur une
    /// recherche naïve — alors que c'est le prix RÉEL de la transaction qui
    /// doit être retenu. Les labels les plus spécifiques passent donc devant
    /// le générique.
    private static let priceLabels = [
        "COURS EXÉCUTÉ", "COURS EXECUTE",
        "COURS D'EXÉCUTION", "COURS D'EXECUTION", "COURS",
        "PRIX D'EXÉCUTION", "PRIX D'EXECUTION", "PRIX UNITAIRE",
        "PRIX DE REVIENT", "PRU", "PRIX",
        "EXECUTION PRICE", "UNIT PRICE", "PRICE"
    ]
    private static let feeLabels = [
        "FRAIS", "COMMISSION", "COURTAGE", "FEES", "FEE"
    ]
    /// Libellés du MONTANT de l'opération, du plus spécifique au plus général.
    ///
    /// ⚠️ Aucun libellé nu (« MONTANT », « TOTAL ») : « Montant total des
    /// frais » et « TOTALENERGIES » y répondraient. Chaque entrée est une
    /// locution complète, et le BRUT passe avant le NET — c'est le brut qui
    /// vaut `quantité × cours`, le net en ayant déjà déduit les frais.
    private static let totalLabels = [
        "MONTANT TRANSACTION BRUT", "MONTANT TOTAL BRUT", "MONTANT BRUT",
        "MONTANT DE L'OPÉRATION", "MONTANT DE L'OPERATION",
        "MONTANT TRANSACTION NET", "MONTANT NET",
        "GROSS AMOUNT", "NET AMOUNT", "TOTAL AMOUNT", "TOTAL COST"
    ]
    /// Libellés du montant NET spécifiquement — distincts de `totalLabels`
    /// (qui mélange brut et net dans un seul repli en cascade) : ici on veut
    /// les DEUX totaux, brut ET net, pour en déduire les frais par différence
    /// quand le libellé direct des frais est introuvable. Cf. `parseBlock`.
    private static let netLabels = [
        "MONTANT NET AU DÉBIT", "MONTANT NET AU DEBIT",
        "MONTANT NET AU CRÉDIT", "MONTANT NET AU CREDIT",
        "MONTANT TRANSACTION NET", "MONTANT NET", "NET AMOUNT"
    ]

    /// Une ligne « plausible » pour être le nom d'un titre : ni une date, ni un
    /// montant, ni un intitulé de champ, ni un ISIN, ni du bruit ponctuation.
    /// Partagé par `assetName` (repli d'affichage) et `nameLineIndex`
    /// (frontière de bloc, cf. `parseBlock`) — les deux posent la MÊME
    /// question (« est-ce que cette ligne ressemble à un nom de titre ? »),
    /// diverger les ferait désigner deux frontières différentes pour le même
    /// bloc.
    private static func isPlausibleNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.count <= 80 else { return false }
        let upper = trimmed.uppercased()
        if firstDate(in: trimmed) != nil { return false }
        if isValidISIN(upper.replacingOccurrences(of: " ", with: "")) { return false }
        if upper.hasPrefix("QUANTIT") || upper.hasPrefix("COURS") || upper.hasPrefix("PRIX")
            || upper.hasPrefix("MONTANT") || upper.hasPrefix("FRAIS") { return false }
        // Une ligne composée uniquement de chiffres/ponctuation n'est pas un nom.
        let letters = trimmed.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }

        // ⚠️ Un nom de valeur porte TOUJOURS une part de majuscules — code
        // court (« AM.PEA EM.ES.T.ACC », « ISHS CO.EURO STOX50 »), raison
        // sociale (« TOTALENERGIES SE ») ou casse de titre (« Epargne MSCI
        // World UCITS ETF »). Une phrase française tout en minuscules est un
        // INTITULÉ DE CHAMP, pas un titre.
        //
        // Bug réel : sur un avis d'opéré BoursoBank, la ligne la plus proche
        // du code ISIN est « Type d'ordre : au marché » — c'est ce libellé qui
        // s'affichait comme nom de la valeur dans l'écran de revue.
        let uppercase = letters.filter { $0.isUppercase }.count
        return Double(uppercase) / Double(letters.count) >= 0.3
    }

    /// Nom du titre : première ligne « plausible » au-dessus de l'ISIN. On
    /// remonte car tous les formats observés (avis d'opéré PDF, écran de
    /// courtier) placent le libellé avant le code.
    private static func assetName(in nameWindow: [String], fallbackAfter fields: [String]) -> String {
        // La ligne LA PLUS PROCHE de l'ISIN gagne : au-dessus se trouvent aussi
        // les en-têtes de l'écran (« Mes mouvements », « Type d'opération »).
        for line in nameWindow.reversed() where isPlausibleNameLine(line) {
            return cleanedName(line)
        }
        // Certains formats mettent le nom APRÈS le code : on tente en aval.
        for line in fields.dropFirst() where isPlausibleNameLine(line) {
            return cleanedName(line)
        }
        return ""
    }

    /// Isole le titre d'une ligne qui porte aussi autre chose.
    ///
    /// Une cellule de tableau aplatie agrège volontiers plusieurs colonnes sur
    /// la même ligne : `4 ISHS CO.EURO STOX50 UC.ETF EUR Référence : 170145383379`.
    /// Deux nettoyages, tous deux indépendants du format :
    ///   • couper à l'entrée du premier CHAMP LIBELLÉ (`Mot :`) — un libellé
    ///     ouvre une autre donnée, le titre le précède ;
    ///   • retirer un nombre isolé en tête, qui est la colonne voisine
    ///     (quantité), jamais le début d'un nom.
    ///
    /// ⚠️ Le libellé recherché est UN SEUL MOT. Autoriser les libellés de
    /// plusieurs mots rendait la coupure trop gourmande : sur « … UC.ETF EUR
    /// Référence : 170145383379 », « EUR Référence » passait pour le libellé et
    /// la devise disparaissait du nom. Un libellé en deux mots ne sera donc pas
    /// coupé — un nom un peu long est moins grave qu'un nom amputé.
    private static func cleanedName(_ line: String) -> String {
        var name = line.trimmingCharacters(in: .whitespaces)
        if let regex = try? NSRegularExpression(pattern: "\\s+[\\p{L}][\\p{L}'’\\-]{2,19}\\s*:\\s"),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range, in: name) {
            name = String(name[..<range.lowerBound])
        }
        if let regex = try? NSRegularExpression(pattern: "^-?\\d+(?:[.,]\\d+)?\\s+") {
            name = regex.stringByReplacingMatches(
                in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Index (dans `nameWindow`) de la ligne de nom la plus proche de l'ISIN —
    /// c'est la frontière entre CE bloc et le bloc PRÉCÉDENT. Utilisé pour
    /// borner le repli des champs numériques (cf. `parseBlock`) : sans cette
    /// frontière, une capture à opérations consécutives laisse les champs du
    /// bloc d'avant (son propre cours, sa propre quantité) contaminer le
    /// repli d'un bloc qui n'affiche légitimement pas ce champ (un dividende
    /// sans cours, par exemple).
    private static func nameLineIndex(in nameWindow: [String]) -> Int? {
        for index in nameWindow.indices.reversed() where isPlausibleNameLine(nameWindow[index]) {
            return index
        }
        return nil
    }

    // MARK: - Dates

    private static let datePatterns: [(regex: NSRegularExpression?, order: [Int])] = [
        // dd/MM/yyyy · dd-MM-yyyy · dd.MM.yyyy
        (try? NSRegularExpression(pattern: "\\b(\\d{1,2})[/.-](\\d{1,2})[/.-](\\d{4})\\b"), [3, 2, 1]),
        // yyyy-MM-dd
        (try? NSRegularExpression(pattern: "\\b(\\d{4})[/.-](\\d{1,2})[/.-](\\d{1,2})\\b"), [1, 2, 3])
    ]

    /// Première date trouvée, normalisée en yyyy-MM-dd.
    static func firstDate(in text: String) -> String? {
        for (regex, order) in datePatterns {
            guard let regex else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            var parts: [String] = []
            for group in order {
                guard let r = Range(match.range(at: group), in: text) else { return nil }
                parts.append(String(text[r]))
            }
            guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1...12).contains(month), (1...31).contains(day), year >= 1900, year <= 2200
            else { continue }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return nil
    }

    // MARK: - Nombres

    /// Variante TOLÉRANTE de `firstNumber(in:labels:)` : le libellé et sa
    /// valeur peuvent être sur des lignes DIFFÉRENTES, pas seulement la même.
    ///
    /// ─── Pourquoi elle existe, en plus de la version stricte ───────────────
    ///
    /// Un avis d'opéré écrit « Quantité exécutée : 2,000 » — libellé et valeur
    /// sur une ligne, la version stricte suffit. Un vrai TABLEAU écrit
    /// l'en-tête de colonne (« Quantité ») sur une ligne et la valeur de la
    /// cellule (« 4 ») sur la ligne de données suivante — deux lignes
    /// distinctes, où la version stricte ne trouve rien. Bug réel : sans cette
    /// variante, la quantité restait introuvable sur ce format.
    ///
    /// ⚠️ Les dates sont RETIRÉES avant la recherche du nombre : sur la ligne
    /// de données d'un tableau, la date de l'opération précède souvent la
    /// quantité (« 13/01/2025 4 ISHS… ») — sans ce retrait, le jour de la
    /// date serait pris pour la quantité qui le suit.
    ///
    /// `lineSpan` borne la recherche à quelques lignes après le libellé : au
    /// même titre que le label lui-même, cette proximité limite le risque de
    /// faux positif sur un nombre sans rapport, plus loin dans le document.
    static func firstNumberNearLabel(in text: String, labels: [String], lineSpan: Int = 2) -> Double? {
        let lines = stripDatesAndTimes(from: text).components(separatedBy: "\n")
        let upperLines = lines.map { $0.uppercased() }

        for label in labels {
            guard let labelLine = upperLines.firstIndex(where: { $0.contains(label) }) else { continue }

            // D'abord la ligne du libellé elle-même — cas « Quantité : 4 »
            // niché dans un tableau par ailleurs, sans qu'une variante stricte
            // n'ait déjà tenté cette ligne précise (labels différents, etc.).
            if let labelRange = upperLines[labelLine].range(of: label) {
                let sameLine = String(upperLines[labelLine][labelRange.upperBound...])
                if let value = firstNumber(in: sameLine) { return value }
            }
            // Puis les lignes suivantes, dans la limite de `lineSpan`.
            var offset = 1
            while offset <= lineSpan, labelLine + offset < lines.count {
                if let value = firstNumber(in: lines[labelLine + offset]) { return value }
                offset += 1
            }
        }
        return nil
    }

    /// Variante de `firstNumberNearLabel` qui prend le DERNIER nombre d'une
    /// ligne de valeurs plutôt que le premier.
    ///
    /// ⚠️ Nécessaire pour un libellé dont la colonne est la DERNIÈRE d'une
    /// rangée groupée (« Montant net », qui clôt toujours le footer d'un avis
    /// d'opéré). Sur une ligne de synthèse à plusieurs colonnes aplatie par
    /// PDFKit (« Montant brut | Commission | Frais | Montant net » en
    /// en-tête, puis leurs valeurs sur la ligne suivante), `firstNumberNearLabel`
    /// renvoie TOUJOURS le premier nombre de la ligne de valeurs — correct
    /// pour le brut (1ʳᵉ colonne), faux pour le net (dernière colonne). Ni
    /// l'une ni l'autre variante ne sait vraiment se positionner par colonne ;
    /// celle-ci exploite juste le fait que le montant net est, par
    /// construction d'un relevé bancaire, toujours le total final.
    static func lastNumberNearLabel(in text: String, labels: [String], lineSpan: Int = 2) -> Double? {
        let lines = stripDatesAndTimes(from: text).components(separatedBy: "\n")
        let upperLines = lines.map { $0.uppercased() }

        for label in labels {
            guard let labelLine = upperLines.firstIndex(where: { $0.contains(label) }) else { continue }
            if let labelRange = upperLines[labelLine].range(of: label) {
                let sameLine = String(upperLines[labelLine][labelRange.upperBound...])
                if let value = lastNumber(in: sameLine) { return value }
            }
            var offset = 1
            while offset <= lineSpan, labelLine + offset < lines.count {
                if let value = lastNumber(in: lines[labelLine + offset]) { return value }
                offset += 1
            }
        }
        return nil
    }

    /// Retire toute date reconnue (cf. `datePatterns`) d'un texte.
    ///
    /// ⚠️ Sert UNIQUEMENT à `firstNumberNearLabel` : la recherche stricte
    /// (`firstNumber(in:labels:)`) doit rester intacte pour ne pas modifier le
    /// comportement déjà éprouvé sur le format « libellé : valeur » ligne à
    /// ligne — seule la variante tolérante, plus permissive par construction,
    /// a besoin de cette protection contre les dates.
    private static func stripDatesAndTimes(from text: String) -> String {
        var result = text
        for (regex, _) in datePatterns {
            guard let regex else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // ⚠️ Les HEURES aussi. Un avis d'opéré horodate son exécution sur sa
        // propre ligne (« 12:30:21 ») : sans ce retrait, la recherche d'une
        // valeur sous un en-tête de colonne y lisait « 12 » comme quantité.
        if let regex = try? NSRegularExpression(pattern: "\\b\\d{1,2}:\\d{2}(?::\\d{2})?\\b") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    /// Valeur numérique suivant l'un des libellés donnés (« Quantité: 7 »,
    /// « Cours 34,53 € », « PRU : 112.76 »).
    static func firstNumber(in text: String, labels: [String]) -> Double? {
        let upper = text.uppercased()
        for label in labels {
            var searchStart = upper.startIndex
            while let labelRange = upper.range(of: label, range: searchStart..<upper.endIndex) {
                let tail = String(upper[labelRange.upperBound...])
                // On borne la fenêtre à la ligne courante : sans ça, un libellé
                // sans valeur happerait le nombre de la ligne suivante (par
                // exemple la quantité d'une AUTRE opération).
                let window = String(tail.prefix(while: { $0 != "\n" }))
                if let value = firstNumber(in: window) { return value }
                searchStart = labelRange.upperBound
            }
        }
        return nil
    }

    /// Premier nombre d'une chaîne, en gérant les deux conventions décimales et
    /// les séparateurs de milliers (espace, espace insécable, apostrophe).
    ///
    /// ⚠️ Le motif doit capturer les DEUX séparateurs d'un coup : découpé après
    /// le premier, « 1,234.56 » se lisait « 1,234 » → 1.234 au lieu de 1234.56.
    static func firstNumber(in text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")   // espace insécable
            .replacingOccurrences(of: "\u{202F}", with: " ")   // espace fine insécable
            .replacingOccurrences(of: "'", with: "")
        guard let regex = try? NSRegularExpression(pattern: "-?\\d+(?:[ .,]\\d+)*") else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: range),
              let r = Range(match.range, in: cleaned) else { return nil }
        return parseNumber(String(cleaned[r]))
    }

    /// Pendant de `firstNumber(in:labels:)`, même fenêtre (ligne courante),
    /// mais dernier nombre plutôt que premier — cf. `lastNumber(in:)`.
    static func lastNumber(in text: String, labels: [String]) -> Double? {
        let upper = text.uppercased()
        for label in labels {
            var searchStart = upper.startIndex
            while let labelRange = upper.range(of: label, range: searchStart..<upper.endIndex) {
                let tail = String(upper[labelRange.upperBound...])
                let window = String(tail.prefix(while: { $0 != "\n" }))
                if let value = lastNumber(in: window) { return value }
                searchStart = labelRange.upperBound
            }
        }
        return nil
    }

    /// Dernier nombre d'une chaîne — pendant de `firstNumber(in:)` pour un
    /// montant qui clôt SYSTÉMATIQUEMENT une ligne de synthèse (le montant
    /// net d'un avis d'opéré est toujours le total final, quel que soit le
    /// nombre de colonnes qui le précèdent). Cf. `lastNumberNearLabel`.
    static func lastNumber(in text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "'", with: "")
        guard let regex = try? NSRegularExpression(pattern: "-?\\d+(?:[ .,]\\d+)*") else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let matches = regex.matches(in: cleaned, range: range)
        guard let last = matches.last, let r = Range(last.range, in: cleaned) else { return nil }
        return parseNumber(String(cleaned[r]))
    }

    /// Convertit un nombre écrit à la française ou à l'anglaise.
    ///
    /// ⚠️ La virgule est ambiguë : séparateur décimal en FR (34,53), séparateur
    /// de milliers en US (1,234.56).
    ///   - Les deux présents → le DERNIER rencontré est le séparateur décimal.
    ///     Couvre « 1,234.56 » (US) comme « 1.234,56 » (DE/FR).
    ///   - Virgule SEULE → décimale. C'est la convention FR, et l'app est
    ///     FR-first : « Quantité exécutée : 2,000 » vaut 2 titres, pas 2000.
    ///     Une seule virgule sans point dans un relevé anglo-saxon (« 1,500
    ///     shares ») serait mal lue — limitation assumée, très minoritaire
    ///     devant le cas FR, et les milliers y sont le plus souvent séparés
    ///     par une espace dans les relevés européens.
    ///   - Plusieurs virgules sans point → milliers (« 1,234,567 »).
    static func parseNumber(_ raw: String) -> Double? {
        var s = raw.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }

        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")
        switch (lastComma, lastDot) {
        case let (comma?, dot?):
            if comma > dot {
                s = s.replacingOccurrences(of: ".", with: "")
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        case (.some, .none):
            s = s.filter { $0 == "," }.count > 1
                ? s.replacingOccurrences(of: ",", with: "")
                : s.replacingOccurrences(of: ",", with: ".")
        default:
            break
        }
        return Double(s)
    }

    /// Montant total signé de la ligne (« -242,92 € », « +1,70 »). Sert à
    /// déduire le prix unitaire quand le cours n'est pas libellé.
    static func signedAmount(in text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        // Un montant porte une PARTIE DÉCIMALE (signée ou non) ou est suivi
        // d'une devise. Les deux conditions comptent :
        //
        // ⚠️ Accepter un entier signé nu faisait lire « COUPONS - 02/07/2026 »
        // comme le montant −2, et le prix unitaire du coupon en était déduit
        // (−2 / 2 = 1 € au lieu de 0,85 €). Un montant d'opération a toujours
        // des centimes ou une devise collée ; une date n'a ni l'un ni l'autre.
        guard let regex = try? NSRegularExpression(
            pattern: "[+-]?\\d[\\d ]*[.,]\\d{1,2}\\b\\s*(?:€|EUR|\\$|USD)?|[+-]?\\d[\\d ]*(?:[.,]\\d+)?\\s*(?:€|EUR|\\$|USD)")
        else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: range),
              let r = Range(match.range, in: cleaned) else { return nil }
        // ⚠️ Le `\s*` de fin de motif avale le saut de ligne : sans le trim,
        // `Double("+1.70\n")` renvoie nil et le montant est silencieusement
        // perdu (le prix unitaire déduit retombait alors à 0).
        let token = String(cleaned[r])
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "EUR", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "USD", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        return parseNumber(token)
    }
}
