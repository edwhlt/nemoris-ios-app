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
        let quantity = firstNumber(in: joined, labels: quantityLabels)
            ?? firstNumberNearLabel(in: preamble, labels: quantityLabels)
        let priceFromLabel = firstNumber(in: joined, labels: priceLabels)
            ?? firstNumberNearLabel(in: preamble, labels: priceLabels)
        let fees = firstNumber(in: joined, labels: feeLabels)
            ?? firstNumberNearLabel(in: preamble, labels: feeLabels) ?? 0
        let gross = signedAmount(in: joined) ?? signedAmount(in: preamble)

        var confidence = 0.85
        if priceFromLabel == nil { confidence -= 0.05 }
        if quantity == nil { confidence -= 0.15 }

        let valuation = valuation(orderType: orderType,
                                  quantity: quantity,
                                  unitPrice: priceFromLabel,
                                  gross: gross)
        if valuation.deduced { confidence -= 0.1 }
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
            notes: "Extraction automatique (sans IA)",
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
        // Quantité absente : le montant devient le prix d'une « unité ».
        if let knownPrice, knownQuantity == nil {
            return (1, knownPrice, true)
        }
        if amount > 0 {
            return (1, amount, true)
        }
        // Rien d'exploitable : on ne fabrique pas un montant.
        return (knownQuantity ?? 0, knownPrice ?? 0, false)
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
        return letters.count >= 3
    }

    /// Nom du titre : première ligne « plausible » au-dessus de l'ISIN. On
    /// remonte car tous les formats observés (avis d'opéré PDF, écran de
    /// courtier) placent le libellé avant le code.
    private static func assetName(in nameWindow: [String], fallbackAfter fields: [String]) -> String {
        // La ligne LA PLUS PROCHE de l'ISIN gagne : au-dessus se trouvent aussi
        // les en-têtes de l'écran (« Mes mouvements », « Type d'opération »).
        for line in nameWindow.reversed() where isPlausibleNameLine(line) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        // Certains formats mettent le nom APRÈS le code : on tente en aval.
        for line in fields.dropFirst() where isPlausibleNameLine(line) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return ""
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
        let lines = stripDates(from: text).components(separatedBy: "\n")
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

    /// Retire toute date reconnue (cf. `datePatterns`) d'un texte.
    ///
    /// ⚠️ Sert UNIQUEMENT à `firstNumberNearLabel` : la recherche stricte
    /// (`firstNumber(in:labels:)`) doit rester intacte pour ne pas modifier le
    /// comportement déjà éprouvé sur le format « libellé : valeur » ligne à
    /// ligne — seule la variante tolérante, plus permissive par construction,
    /// a besoin de cette protection contre les dates.
    private static func stripDates(from text: String) -> String {
        var result = text
        for (regex, _) in datePatterns {
            guard let regex else { continue }
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
