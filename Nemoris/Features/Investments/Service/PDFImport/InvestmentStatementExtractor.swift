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
            // ⚠️ Deux fenêtres DISTINCTES, et c'est ce qui rend l'extraction
            // fiable sur les captures d'app :
            //
            //   • champs (date, quantité, cours, montant) → APRÈS l'ISIN,
            //     jusqu'à l'ISIN suivant. Les prendre « autour » de l'ISIN
            //     faisait remonter les champs de l'opération PRÉCÉDENTE (la
            //     quantité du bloc 1 se retrouvait sur le bloc 2).
            //   • nom du titre → AVANT l'ISIN, sans jamais franchir l'ISIN
            //     précédent. Tous les formats observés (avis d'opéré PDF,
            //     écran de courtier) placent le libellé au-dessus du code.
            let fieldsUpper = index == anchors.count - 1
                ? lines.count - 1
                : min(lines.count - 1, anchors[index + 1].line - 1)
            guard anchor.line <= fieldsUpper else { continue }
            let fields = Array(lines[anchor.line...fieldsUpper])

            let nameLower = index == 0
                ? max(0, anchor.line - 5)
                : max(anchors[index - 1].line + 1, anchor.line - 5)
            let nameWindow = nameLower < anchor.line
                ? Array(lines[nameLower..<anchor.line])
                : []

            if let order = parseBlock(fields: fields, nameWindow: nameWindow, isin: anchor.isin) {
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

        let quantity = firstNumber(in: joined, labels: quantityLabels)
        let priceFromLabel = firstNumber(in: joined, labels: priceLabels)
        let fees = firstNumber(in: joined, labels: feeLabels) ?? 0
        let gross = signedAmount(in: joined)

        // Le prix unitaire peut être absent (lignes de dividende, formats
        // condensés) : on le déduit du montant total quand c'est possible.
        var confidence = 0.85
        var unitPrice = priceFromLabel ?? 0
        if unitPrice == 0, let gross, let qty = quantity, qty > 0 {
            unitPrice = abs(gross) / qty
            confidence -= 0.1
        }
        if priceFromLabel == nil { confidence -= 0.05 }
        if quantity == nil { confidence -= 0.15 }

        let name = assetName(in: nameWindow, fallbackAfter: fields)
        if name.isEmpty { confidence -= 0.2 }

        return ExtractedStatementOrder(
            orderType: orderType,
            assetName: name.isEmpty ? isin : name,
            isin: isin,
            quantity: quantity ?? 0,
            unitPrice: unitPrice,
            fees: fees,
            executedAt: date,
            currency: detectCurrency(in: upper),
            notes: "Extraction automatique (sans IA)",
            confidence: max(0.2, min(1, confidence))
        )
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
    private static let priceLabels = [
        "COURS D'EXÉCUTION", "COURS D'EXECUTION", "COURS", "PRIX UNITAIRE",
        "PRIX DE REVIENT", "PRU", "PRIX", "UNIT PRICE", "PRICE"
    ]
    private static let feeLabels = [
        "FRAIS", "COMMISSION", "COURTAGE", "FEES", "FEE"
    ]

    /// Nom du titre : première ligne « plausible » au-dessus de l'ISIN. On
    /// remonte car tous les formats observés (avis d'opéré PDF, écran de
    /// courtier) placent le libellé avant le code.
    private static func assetName(in nameWindow: [String], fallbackAfter fields: [String]) -> String {
        func isPlausible(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, trimmed.count <= 80 else { return false }
            let upper = trimmed.uppercased()
            // Ni une date, ni un montant, ni un intitulé de champ, ni un ISIN.
            if firstDate(in: trimmed) != nil { return false }
            if isValidISIN(upper.replacingOccurrences(of: " ", with: "")) { return false }
            if upper.hasPrefix("QUANTIT") || upper.hasPrefix("COURS") || upper.hasPrefix("PRIX")
                || upper.hasPrefix("MONTANT") || upper.hasPrefix("FRAIS") { return false }
            // Une ligne composée uniquement de chiffres/ponctuation n'est pas un nom.
            let letters = trimmed.filter { $0.isLetter }
            return letters.count >= 3
        }

        // La ligne LA PLUS PROCHE de l'ISIN gagne : au-dessus se trouvent aussi
        // les en-têtes de l'écran (« Mes mouvements », « Type d'opération »).
        for line in nameWindow.reversed() where isPlausible(line) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        // Certains formats mettent le nom APRÈS le code : on tente en aval.
        for line in fields.dropFirst() where isPlausible(line) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return ""
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
