import Foundation

// MARK: - Deterministic extraction of operations from a statement / capture
//
// PURE engine (no network, disk, AI or SwiftUI access) — same doctrine as
// `PortfolioEvolutionBuilder` and `MerchantQueryPlanner`: testable outside Xcode.
//
// ─── Why a deterministic engine ─────────────────────────────────────────────
//
// Relying on AI alone for statement import has three consequences:
//   1. On a device without an AI backend (iOS 18-25, an ineligible Mac, the
//      feature disabled), the import could extract NOTHING — even though a
//      bank statement is a very regular tabular format.
//   2. When the model fails (context exceeded, malformed JSON), the result
//      is indistinguishable from a genuinely empty document.
//   3. No safety net: a 100% probabilistic extraction.
//
// This engine does NOT try to beat the AI on free-form formats. It covers the
// dominant case — an operation row identified by its ISIN — and serves as a
// systematic backbone reconciled with the AI's reading.
//
// ─── Anchoring on the ISIN ─────────────────────────────────────────────────
//
// The ISIN is the only truly reliable identifier in a statement: a
// normalized format (ISO 6166), present on every trade confirmation and most
// broker screens. The text is therefore split into blocks around each ISIN
// found, then the other fields are looked for IN that block. Mobile app OCR
// text arrives as a column (one field per line), a PDF arrives as a table:
// splitting by ISIN absorbs both.

/// An operation recognized without AI. Deliberately distinct from
/// `PDFExtractedOrder` (which carries UI state): this engine stays pure.
struct ExtractedStatementOrder: Equatable, Codable, Hashable, Sendable {
    var orderType: String        // "BUY" | "SELL" | "DIV"
    var assetName: String
    var isin: String
    /// Short stock symbol. The ONLY field ISIN anchoring doesn't look for (it has
    /// no normalized form): it's filled by the reconciliation, from the AI or
    /// from a structured format that names it. Defaulted so the deterministic
    /// engine's construction sites stay unchanged.
    var ticker: String = ""
    var quantity: Double
    var unitPrice: Double
    var fees: Double
    /// Date as yyyy-MM-dd (a string: the engine doesn't depend on Calendar).
    var executedAt: String
    var currency: String
    var notes: String?
    /// Confidence: lowered when a field had to be deduced rather than read.
    var confidence: Double
}

enum InvestmentStatementExtractor {

    // MARK: - Entry point

    /// Extracts every recognizable operation from raw text.
    static func extractOrders(from text: String) -> [ExtractedStatementOrder] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let anchors = isinAnchors(in: lines)
        guard !anchors.isEmpty else { return [] }

        var results: [ExtractedStatementOrder] = []
        for (index, anchor) in anchors.enumerated() {
            // Two windows, bounded by the NEIGHBORING anchors and never by each other —
            // which keeps a field from leaking in from the previous or next block,
            // without locking it into an arbitrary number of lines:
            //
            //   • AFTER the ISIN, up to the next ISIN: the dominant case for a trade
            //     confirmation ("Executed quantity: 2,000" comes after the code).
            //   • BEFORE the ISIN, from the previous ISIN: needed for a real TABLE (not
            //     column text). There the ISIN is the 2nd sub-line of its cell ("ISIN
            //     code: …" under the security's name), while a neighboring cell of the
            //     SAME visual row — the quantity, aligned with the date — ends up BEFORE
            //     it once PDFKit flattens the table into text.
            //
            // The label ("Quantité", "Cours", "Frais") guards against false positives in
            // the BEFORE window — a bank header never contains those words — so widening
            // it costs nothing in precision, unlike a fixed number of lines that could
            // cut the table in the wrong place depending on its layout.
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

    /// An ISIN: 2 country letters + 9 alphanumerics + 1 check digit.
    /// The Luhn key is validated to rule out false positives (an internal bank
    /// reference can have the same shape).
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

    /// ISO 6166 validation: letters converted to numbers (A=10 … Z=35), then Luhn
    /// on the resulting digit string.
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
        var double = true   // double starting from the right, excluding the last digit
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

    // MARK: - Parsing a block

    private static func parseBlock(fields: [String], nameWindow: [String], isin: String) -> ExtractedStatementOrder? {
        let joined = fields.joined(separator: "\n")
        let upper = joined.uppercased()
        // Fall back on the name when the type or the date are ABOVE the code (some
        // formats title "Achat — 15/03/2024" before the ISIN).
        let fallback = nameWindow.joined(separator: "\n")

        guard let orderType = detectOrderType(in: upper) ?? detectOrderType(in: fallback.uppercased()) else { return nil }
        guard let date = firstDate(in: joined) ?? firstDate(in: fallback) else { return nil }

        // Fallback BEFORE the ISIN for each numeric field — but restricted to THIS
        // block's PREAMBLE, not the whole `nameWindow`.
        //
        // On a real table, the column header ("Quantité") and its value ("4") are
        // legitimately before the ISIN. But on a capture with several consecutive
        // operations, `nameWindow` ALSO contains the end of the PREVIOUS block's
        // fields (its own quantity, its own price) — and a dividend without a
        // displayed price would grab the price of the security bought just before it.
        //
        // The name line closest to the ISIN (computed by `assetName` below,
        // anticipated here) marks the boundary: everything before it structurally
        // belongs to the PREVIOUS block.
        let preambleStart = nameLineIndex(in: nameWindow) ?? 0
        let preamble = preambleStart < nameWindow.count
            ? Array(nameWindow[preambleStart...]).joined(separator: "\n")
            : ""

        // `firstNumberNearLabel`, not `firstNumber`, for this fallback: in a table,
        // the column HEADER and its VALUE are on two DIFFERENT lines (header line,
        // then data line) — `firstNumber` requires the same line. The tolerant
        // variant searches the few lines following the label, after removing the
        // recognized dates: otherwise the day of a date on the data line
        // ("13/01/2025 4 …") would be taken for the quantity that follows it.
        // The tolerant variant applies to BOTH windows, not only the preamble. In a
        // table, the column header and its value sit on two distinct lines on both
        // sides of the anchor — a confirmation's fees ("Commission …" then
        // "1,11 EUR …") fall AFTER the ISIN code, in a window where a strict,
        // same-line search would never read them.
        let quantity = firstNumber(in: joined, labels: quantityLabels)
            ?? firstNumberNearLabel(in: joined, labels: quantityLabels)
            ?? firstNumberNearLabel(in: preamble, labels: quantityLabels)
        let priceFromLabel = firstNumber(in: joined, labels: priceLabels)
            ?? firstNumberNearLabel(in: joined, labels: priceLabels)
            ?? firstNumberNearLabel(in: preamble, labels: priceLabels)
        var fees = firstNumber(in: joined, labels: feeLabels)
            ?? firstNumberNearLabel(in: joined, labels: feeLabels)
            ?? firstNumberNearLabel(in: preamble, labels: feeLabels) ?? 0

        // The LABELED amount wins over "the block's first amount".
        //
        // A BoursoBank confirmation block opens on "Code ISIN … Cours exécuté :
        // 55,62 EUR", so taking the first amount would pick the PRICE as the
        // operation's amount — the real total, "Montant transaction brut
        // 222,48 EUR", comes further down. The quantity could then no longer be
        // deduced (55.62 ÷ 55.62 = 1), and the order would import as "1 × €55.62"
        // instead of "4 × €55.62".
        //
        // A statement that gives a total always LABELS it; the unlabeled fallback
        // remains for app captures, where the amount sits alone on its line with no
        // header.
        let gross = firstNumber(in: joined, labels: totalLabels)
            ?? firstNumberNearLabel(in: joined, labels: totalLabels)
            ?? firstNumber(in: preamble, labels: totalLabels)
            ?? firstNumberNearLabel(in: preamble, labels: totalLabels)
            ?? signedAmount(in: joined) ?? signedAmount(in: preamble)

        // IMPLAUSIBLE fees rejected before any fallback. `firstNumberNearLabel` has
        // no notion of COLUMN: on the VALUE line of a 4-column footer ("Montant brut
        // | Commission | Frais | Montant net"), it returns the line's FIRST number —
        // which is the gross amount, not the commission, whenever "Commission" isn't
        // the 1st column. Returned fees equal to EXACTLY the gross amount double the
        // displayed total (`quantity × price + fees`). A plausible commission stays a
        // SMALL fraction of the operation's amount; a number found "for the fees"
        // that approaches the gross amount isn't a reading, it's a column mix-up —
        // treated as if nothing had been found, leaving room for the subtraction
        // fallback below.
        if let grossValue = gross, grossValue > 0, fees >= grossValue * 0.5 {
            fees = 0
        }

        // Fallback by SUBTRACTION when no direct fee label worked ("Commission" /
        // "Frais" not found, or rejected above as implausible). A 4-column footer
        // (Montant brut | Commission | Frais (♦) | Montant net au débit) often groups
        // its 4 HEADERS in one block before its 4 VALUES once PDFKit flattens the
        // table — the "Commission" value may then land more than `lineSpan` lines
        // from its label, or in the wrong column of a grouped value line. Rather than
        // complicating the search by position, the fees are deduced from the
        // difference between the NET and the GROSS amounts — two totals the document
        // almost always gives, each clearly identified by its own full label at the
        // end of the line, independent of an isolated cell's position in a layout
        // that varies from one broker to the next. `abs(...)` works both ways: a
        // purchase pays more than the gross (net > gross), a sale receives less
        // (net < gross).
        if fees == 0, let grossValue = gross {
            // `lastNumberNearLabel`, not `firstNumberNearLabel`: "Montant net" is the
            // footer's LAST column, whereas the "first" variant — meant for "Montant
            // brut", the 1st column — would STILL return the gross amount on the grouped
            // value line, making `net == grossValue` and the subtraction zero.
            let net = lastNumber(in: joined, labels: netLabels)
                ?? lastNumberNearLabel(in: joined, labels: netLabels)
                ?? lastNumber(in: preamble, labels: netLabels)
                ?? lastNumberNearLabel(in: preamble, labels: netLabels)
            if let net {
                let derived = abs(net - grossValue)
                // Guard: fees don't normally exceed the gross amount itself — beyond that,
                // the two numbers found probably don't describe the same operation (two
                // neighboring rows of a multi-operation statement).
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

        // A quantity DERIVED from `amount ÷ price`, when BOTH are labeled in the
        // document, isn't a guess: it's a check. `4 × 55.62 = 222.48` reproduces
        // exactly the gross amount printed on the confirmation. It therefore stays
        // ABOVE the review threshold (`StatementReconciler.uncertainConfidence`) —
        // otherwise a model answering "quantity 1" would overwrite an arithmetically
        // exact value.
        //
        // Without both anchors, on the other hand, the quantity is "1" for lack of
        // anything better: a real unknown, which the AI must be able to correct.
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
            // A NEUTRAL note rather than "without AI": the operation may be reinforced
            // right after by `StatementReconciler`, and the note would then claim the
            // opposite of what happened.
            notes: "Extraction automatique (ancrage ISIN)",
            confidence: max(0.2, min(1, confidence))
        )
    }

    // MARK: - Valuing an operation

    /// Consistent quantity and unit price, so that `quantity × price` is ALWAYS
    /// the operation's real amount.
    ///
    /// A DIVIDEND has neither a quantity nor an execution price: its value IS the
    /// credited amount. Forcing it into the "quantity × price" mold would give a
    /// zero price, hence a **€0** dividend. Same trap for a purchase whose
    /// document doesn't name the quantity: it would fall to 0, and the total
    /// with it.
    ///
    /// Rule: when the document gives an AMOUNT, the operation is never worth
    /// zero. With an unknown quantity, 1 is used and the amount becomes the unit
    /// price — the value is right, and that's what matters for the portfolio.
    /// When the quantity is known (100 shares for a €34.53 coupon), the unit
    /// price is derived from it and the product stays exact.
    ///
    /// PURE engine, shared with the AI path (`InvestmentPDFParser.convert`): a
    /// deterministic extraction and a model extraction must not value the same
    /// operation differently.
    static func valuation(orderType: String,
                          quantity: Double?,
                          unitPrice: Double?,
                          gross: Double?) -> (quantity: Double, unitPrice: Double, deduced: Bool) {
        let amount = gross.map(abs) ?? 0
        let knownQuantity = (quantity ?? 0) > 0 ? quantity! : nil
        let knownPrice = (unitPrice ?? 0) > 0 ? unitPrice! : nil

        // Nominal case: both are read from the document.
        if let knownQuantity, let knownPrice {
            return (knownQuantity, knownPrice, false)
        }
        // Price missing but amount known: deduce it.
        if let knownQuantity, amount > 0 {
            return (knownQuantity, amount / knownQuantity, true)
        }
        // Quantity missing, but PRICE and AMOUNT known: `quantity = amount ÷ price`.
        // That's arithmetic, not a layout heuristic — so it holds whatever the
        // broker, where no search window around a label can cover every possible
        // arrangement.
        //
        // On a BoursoBank confirmation, the quantity "4" sits THREE lines below its
        // column header once PDFKit flattens the table — unfindable by label. But
        // "Montant transaction brut 222,48 EUR" and "Cours exécuté : 55,62 EUR" are
        // both labeled, and their quotient is exactly 4.
        if let knownPrice, amount > 0 {
            let derived = amount / knownPrice
            // Guard: an absurd ratio means two unrelated quantities were compared (a fee
            // amount with a price, for example) — better to deduce nothing then.
            if derived.isFinite, derived > 0, derived < 1_000_000 {
                return (snappedToWhole(derived), knownPrice, true)
            }
        }
        // Quantity missing and no amount: the price becomes that of one "unit".
        if let knownPrice, knownQuantity == nil {
            return (1, knownPrice, true)
        }
        if amount > 0 {
            return (1, amount, true)
        }
        // Rien d'exploitable : on ne fabrique pas un montant.
        return (knownQuantity ?? 0, knownPrice ?? 0, false)
    }

    /// Rounds a quantity deduced from a division when it's very close to an
    /// integer.
    ///
    /// Very tight tolerance, on purpose: ETF and fund shares are held in
    /// fractions (0.347 share), so only the rounding residue of an exact division
    /// (222.48 ÷ 55.62) is "corrected", never a genuinely fractional quantity.
    private static func snappedToWhole(_ value: Double) -> Double {
        let rounded = value.rounded()
        guard rounded >= 1, abs(value - rounded) < 0.001 else { return value }
        return rounded
    }

    // MARK: - Champs

    /// Operation keywords, from the most specific to the most general: "ACHAT
    /// COMPTANT" and "SOUSCRIPTION" before the plain "ACH", otherwise a label
    /// containing "ACHAT" in an unrelated phrase would trigger a false BUY.
    private static let buyKeywords  = ["ACHAT", "ACQUISITION", "SOUSCRIPTION", "BUY", "KAUF", "COMPRA", "ACH "]
    private static let sellKeywords = ["VENTE", "CESSION", "RACHAT", "SELL", "VERKAUF", "VENTA", "VTE "]
    private static let divKeywords  = ["COUPON", "DIVIDENDE", "DIVIDEND", "DISTRIBUTION", "DÉTACHEMENT", "DETACHEMENT"]

    static func detectOrderType(in upperText: String) -> String? {
        // Dividend tested first: a mixed statement often lists purchases AND coupons
        // — the block decides, and the dividend word is the most discriminating one
        // in it.
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

    /// Field labels, FR and EN — an Interactive Brokers or Trade Republic
    /// statement writes "Quantity" / "Price", not "Quantité" / "Cours".
    private static let quantityLabels = [
        "QUANTITÉ EXÉCUTÉE", "QUANTITE EXECUTEE", "QUANTITÉ", "QUANTITE",
        "QTÉ", "QTE", "NOMBRE DE PARTS", "NOMBRE", "QUANTITY", "SHARES", "UNITS"
    ]
    /// "Cours exécuté" WINS over "Cours demandé": a limit order can request one
    /// price and execute at another. The generic "COURS" label would match
    /// "Cours demandé", which often appears BEFORE "Cours exécuté" in a trade
    /// confirmation — hence first in a naive search — whereas the transaction's
    /// REAL price is the one to keep. The most specific labels therefore come
    /// before the generic one.
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
    /// Labels of the operation's AMOUNT, from the most specific to the most general.
    ///
    /// No bare label ("MONTANT", "TOTAL"): "Montant total des frais" and
    /// "TOTALENERGIES" would match. Each entry is a complete phrase, and GROSS
    /// comes before NET — the gross equals `quantity × price`, the net having
    /// already deducted the fees.
    private static let totalLabels = [
        "MONTANT TRANSACTION BRUT", "MONTANT TOTAL BRUT", "MONTANT BRUT",
        "MONTANT DE L'OPÉRATION", "MONTANT DE L'OPERATION",
        "MONTANT TRANSACTION NET", "MONTANT NET",
        "GROSS AMOUNT", "NET AMOUNT", "TOTAL AMOUNT", "TOTAL COST"
    ]
    /// Labels of the NET amount specifically — distinct from `totalLabels`
    /// (which mixes gross and net in a single cascading fallback): here BOTH
    /// totals, gross AND net, are wanted, to deduce the fees by difference when
    /// the direct fee label can't be found. See `parseBlock`.
    private static let netLabels = [
        "MONTANT NET AU DÉBIT", "MONTANT NET AU DEBIT",
        "MONTANT NET AU CRÉDIT", "MONTANT NET AU CREDIT",
        "MONTANT TRANSACTION NET", "MONTANT NET", "NET AMOUNT"
    ]

    /// A line "plausible" as a security's name: not a date, not an amount, not a
    /// field heading, not an ISIN, not punctuation noise. Shared by `assetName`
    /// (display fallback) and `nameLineIndex` (block boundary, see `parseBlock`)
    /// — both ask the SAME question ("does this line look like a security
    /// name?"); diverging would make them designate two different boundaries for
    /// the same block.
    private static func isPlausibleNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.count <= 80 else { return false }
        let upper = trimmed.uppercased()
        if firstDate(in: trimmed) != nil { return false }
        if isValidISIN(upper.replacingOccurrences(of: " ", with: "")) { return false }
        if upper.hasPrefix("QUANTIT") || upper.hasPrefix("COURS") || upper.hasPrefix("PRIX")
            || upper.hasPrefix("MONTANT") || upper.hasPrefix("FRAIS") { return false }
        // A line made only of digits/punctuation isn't a name.
        let letters = trimmed.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }

        // A security name ALWAYS carries some uppercase — a short code
        // ("AM.PEA EM.ES.T.ACC", "ISHS CO.EURO STOX50"), a company name
        // ("TOTALENERGIES SE") or title case ("Epargne MSCI World UCITS ETF"). An
        // all-lowercase French sentence is a FIELD HEADING, not a security.
        //
        // On a BoursoBank confirmation, the line closest to the ISIN code is "Type
        // d'ordre : au marché" — without this rule, that heading would show as the
        // security's name in the review screen.
        let uppercase = letters.filter { $0.isUppercase }.count
        return Double(uppercase) / Double(letters.count) >= 0.3
    }

    /// Security name: the first "plausible" line above the ISIN. Searching
    /// upwards, because every observed format (PDF trade confirmation, broker
    /// screen) puts the label before the code.
    private static func assetName(in nameWindow: [String], fallbackAfter fields: [String]) -> String {
        // The line CLOSEST to the ISIN wins: above it also sit the screen's headers
        // ("Mes mouvements", "Type d'opération").
        for line in nameWindow.reversed() where isPlausibleNameLine(line) {
            return cleanedName(line)
        }
        // Some formats put the name AFTER the code: try downstream.
        for line in fields.dropFirst() where isPlausibleNameLine(line) {
            return cleanedName(line)
        }
        return ""
    }

    /// Isolates the security's name from a line that also carries something else.
    ///
    /// A flattened table cell readily aggregates several columns on the same
    /// line: `4 ISHS CO.EURO STOX50 UC.ETF EUR Référence : 170145383379`.
    /// Two cleanups, both format-independent:
    ///   • cut at the start of the first LABELED FIELD (`Word :`) — a label opens
    ///     another piece of data, the name comes before it;
    ///   • remove an isolated number at the start, which is the neighboring
    ///     column (quantity), never the start of a name.
    ///
    /// The label looked for is A SINGLE WORD. Allowing multi-word labels made the
    /// cut too greedy: on "… UC.ETF EUR Référence : 170145383379", "EUR Référence"
    /// would pass for the label and the currency would vanish from the name. A
    /// two-word label is therefore not cut — a slightly long name is less harmful
    /// than a truncated one.
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

    /// Index (in `nameWindow`) of the name line closest to the ISIN — the
    /// boundary between THIS block and the PREVIOUS one. Bounds the fallback of
    /// numeric fields (see `parseBlock`): without it, on a capture with
    /// consecutive operations, the previous block's fields (its own price, its
    /// own quantity) would contaminate the fallback of a block that legitimately
    /// doesn't show that field (a dividend without a price, for instance).
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

    /// First date found, normalized as yyyy-MM-dd.
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

    /// TOLERANT variant of `firstNumber(in:labels:)`: the label and its value may
    /// be on DIFFERENT lines, not only the same one.
    ///
    /// ─── Why it exists, alongside the strict version ───────────────────────
    ///
    /// A trade confirmation writes "Quantité exécutée : 2,000" — label and value
    /// on one line, the strict version is enough. A real TABLE writes the column
    /// header ("Quantité") on one line and the cell's value ("4") on the next
    /// data line — two distinct lines, where the strict version finds nothing.
    ///
    /// Dates are REMOVED before looking for the number: on a table's data line,
    /// the operation's date often precedes the quantity ("13/01/2025 4 ISHS…") —
    /// otherwise the day of the date would be taken for the quantity that
    /// follows it.
    ///
    /// `lineSpan` bounds the search to a few lines after the label: like the
    /// label itself, this proximity limits the risk of a false positive on an
    /// unrelated number further down the document.
    static func firstNumberNearLabel(in text: String, labels: [String], lineSpan: Int = 2) -> Double? {
        let lines = stripDatesAndTimes(from: text).components(separatedBy: "\n")
        let upperLines = lines.map { $0.uppercased() }

        for label in labels {
            guard let labelLine = upperLines.firstIndex(where: { $0.contains(label) }) else { continue }

            // First the label's own line — the "Quantité : 4" case nested in an
            // otherwise tabular layout, where no strict variant has already tried this
            // precise line (different labels, etc.).
            if let labelRange = upperLines[labelLine].range(of: label) {
                let sameLine = String(upperLines[labelLine][labelRange.upperBound...])
                if let value = firstNumber(in: sameLine) { return value }
            }
            // Then the following lines, within `lineSpan`.
            var offset = 1
            while offset <= lineSpan, labelLine + offset < lines.count {
                if let value = firstNumber(in: lines[labelLine + offset]) { return value }
                offset += 1
            }
        }
        return nil
    }

    /// Variant of `firstNumberNearLabel` that takes the LAST number of a value
    /// line rather than the first.
    ///
    /// Needed for a label whose column is the LAST of a grouped row ("Montant
    /// net", which always closes a trade confirmation's footer). On a
    /// multi-column summary line flattened by PDFKit ("Montant brut | Commission
    /// | Frais | Montant net" as headers, then their values on the next line),
    /// `firstNumberNearLabel` ALWAYS returns the value line's first number —
    /// right for the gross (1st column), wrong for the net (last column). Neither
    /// variant can truly position itself by column; this one just exploits the
    /// fact that the net amount is, by construction of a bank statement, always
    /// the final total.
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

    /// Removes every recognized date (see `datePatterns`) from a text.
    ///
    /// Used ONLY by `firstNumberNearLabel`: the strict search
    /// (`firstNumber(in:labels:)`) must stay untouched so the proven behavior on
    /// the line-by-line "label: value" format doesn't change — only the tolerant
    /// variant, more permissive by construction, needs this protection against
    /// dates.
    private static func stripDatesAndTimes(from text: String) -> String {
        var result = text
        for (regex, _) in datePatterns {
            guard let regex else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // TIMES too. A trade confirmation timestamps its execution on its own line
        // ("12:30:21"): otherwise the search for a value under a column header would
        // read "12" as the quantity.
        if let regex = try? NSRegularExpression(pattern: "\\b\\d{1,2}:\\d{2}(?::\\d{2})?\\b") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    /// Numeric value following one of the given labels ("Quantité: 7",
    /// "Cours 34,53 €", "PRU : 112.76").
    static func firstNumber(in text: String, labels: [String]) -> Double? {
        let upper = text.uppercased()
        for label in labels {
            var searchStart = upper.startIndex
            while let labelRange = upper.range(of: label, range: searchStart..<upper.endIndex) {
                let tail = String(upper[labelRange.upperBound...])
                // The window is bounded to the current line: otherwise a label without a
                // value would grab the number from the next line (for example ANOTHER
                // operation's quantity).
                let window = String(tail.prefix(while: { $0 != "\n" }))
                if let value = firstNumber(in: window) { return value }
                searchStart = labelRange.upperBound
            }
        }
        return nil
    }

    /// First number of a string, handling both decimal conventions and thousands
    /// separators (space, non-breaking space, apostrophe).
    ///
    /// The pattern must capture BOTH separators at once: cut after the first,
    /// "1,234.56" would read "1,234" → 1.234 instead of 1234.56.
    static func firstNumber(in text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking space
            .replacingOccurrences(of: "\u{202F}", with: " ")   // narrow non-breaking space
            .replacingOccurrences(of: "'", with: "")
        guard let regex = try? NSRegularExpression(pattern: "-?\\d+(?:[ .,]\\d+)*") else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: range),
              let r = Range(match.range, in: cleaned) else { return nil }
        return parseNumber(String(cleaned[r]))
    }

    /// Counterpart of `firstNumber(in:labels:)`, same window (current line), but
    /// the last number rather than the first — see `lastNumber(in:)`.
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

    /// Last number of a string — counterpart of `firstNumber(in:)` for an amount
    /// that ALWAYS closes a summary line (a trade confirmation's net amount is
    /// always the final total, however many columns precede it). See
    /// `lastNumberNearLabel`.
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

    /// Converts a number written the French or the English way.
    ///
    /// The comma is ambiguous: a decimal separator in FR (34,53), a thousands
    /// separator in US (1,234.56).
    ///   - Both present → the LAST one encountered is the decimal separator.
    ///     Covers "1,234.56" (US) as well as "1.234,56" (DE/FR).
    ///   - A comma ALONE → decimal. That's the FR convention, and the app is
    ///     FR-first: "Quantité exécutée : 2,000" means 2 shares, not 2000. A
    ///     single comma without a dot in an English statement ("1,500 shares")
    ///     would be misread — an accepted limitation, far rarer than the FR
    ///     case, and European statements usually separate thousands with a space.
    ///   - Several commas without a dot → thousands ("1,234,567").
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

    /// Signed total amount of the line ("-242,92 €", "+1,70"). Used to deduce the
    /// unit price when the price isn't labeled.
    static func signedAmount(in text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        // An amount carries a DECIMAL PART (signed or not) or is followed by a
        // currency. Both conditions matter:
        //
        // Accepting a bare signed integer would read "COUPONS - 02/07/2026" as the
        // amount −2, and the coupon's unit price would be deduced from it (−2 / 2 =
        // €1 instead of €0.85). An operation amount always has cents or an attached
        // currency; a date has neither.
        guard let regex = try? NSRegularExpression(
            pattern: "[+-]?\\d[\\d ]*[.,]\\d{1,2}\\b\\s*(?:€|EUR|\\$|USD)?|[+-]?\\d[\\d ]*(?:[.,]\\d+)?\\s*(?:€|EUR|\\$|USD)")
        else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: range),
              let r = Range(match.range, in: cleaned) else { return nil }
        // The pattern's trailing `\s*` swallows the line break: without the trim,
        // `Double("+1.70\n")` returns nil and the amount is silently lost (the
        // deduced unit price would then fall back to 0).
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
