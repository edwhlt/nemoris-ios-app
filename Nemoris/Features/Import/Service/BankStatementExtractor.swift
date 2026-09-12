import Foundation

// MARK: - Deterministic extraction of operations from a bank statement
//
// PURE engine (no network, disk, AI or SwiftUI access) — same doctrine as
// `InvestmentStatementExtractor`, `PortfolioEvolutionBuilder` and
// `MerchantQueryPlanner`: testable outside Xcode via `run_bank_statement_tests.sh`.
//
// ─── Why this engine exists ────────────────────────────────────────────────
//
// Transaction import only knew CSV. A PDF statement or a screenshot
// of a banking app had no entry path at all, even though it's a very
// regular tabular format. Handing it 100% to AI would have reproduced the
// three flaws already paid for on the investments side: nothing at all
// without Apple Intelligence, a failure indistinguishable from an empty
// document, and no safety net against a probabilistic extraction.
//
// ─── Anchoring on the DATE, not an identifier ──────────────────────────────
//
// A bank statement has no equivalent of an ISIN. The invariant we can
// exploit is that an operation ALWAYS carries a full date and an amount. So
// we anchor on the date (day/month/year, never a short form) and
// look for the amount on the same line — or just below when the text
// arrives in a column, which is what screenshot OCR produces.
//
// This engine doesn't try to beat AI on exotic layouts: it
// covers the dominant case and serves as a systematic safety net. Reconciliation
// (`TransactionDocumentParser.reconcile`) leaves it in charge of the date and
// the amount — where a small model copies or derives them — and takes the
// AI's label, which reconstructs OCR text broken across columns better.

/// A bank operation recognized without AI. Deliberately distinct from
/// `ImportSessionRow` (which carries resolution and UI state): this engine
/// stays pure and knows neither the database nor the identification engine.
struct ExtractedBankTransaction: Equatable, Codable, Hashable, Sendable {
    /// Date in yyyy-MM-dd format (a string: the engine doesn't depend on Calendar).
    var date: String
    /// SIGNED amount, app convention: negative = expense.
    var amount: Double
    var label: String
    /// "CB" | "VIREMENT" | "PRELEVEMENT" | "RETRAIT" | "CHEQUE", si reconnaissable.
    var paymentTypeHint: String?
    /// True when the sign comes from an explicit marker (+ or − attached to
    /// the amount). False when it was inferred from a label keyword or the
    /// "expense" default — that's the information reconciliation
    /// needs to know whether it can trust the AI's sign.
    var isSignExplicit: Bool
    /// Confidence: downgraded when a field had to be inferred rather than read.
    var confidence: Double
}

enum BankStatementExtractor {

    // MARK: - Entry point

    /// Extracts every recognizable operation from plain text.
    /// Returns an empty array rather than inventing anything: a document with no
    /// date or amount produces nothing, never a "just in case" line.
    ///
    /// `referenceDate` resolves dates WITHOUT a year ("Jul 2",
    /// "Yesterday"), ubiquitous in banking app screenshots. An explicit
    /// parameter rather than a hardcoded `Date()`: the engine stays
    /// deterministic and testable.
    static func extractTransactions(from text: String,
                                    referenceDate: Date = Date()) -> [ExtractedBankTransaction] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return [] }

        let infos = lines.map(LineInfo.init(raw:))
        var results: [ExtractedBankTransaction] = []
        /// Last line already attached to an operation — bounds the label
        /// windows so a block never reaches back into the previous one.
        var lastConsumed = -1

        for index in infos.indices {
            let info = infos[index]
            guard let date = resolvedDate(info, reference: referenceDate), !info.isSummary else { continue }
            // A line already consumed as an amount or as a continuation of a
            // previous block doesn't open a new block.
            guard index > lastConsumed else { continue }

            // ─── DATE-HEADER layout ──────────────────────────────────────────
            // Banking apps group the day under a single header,
            // then list the operations in a row: "July 22" / merchant /
            // category / amount / merchant / category / amount…
            // The "one date = one operation" model therefore only kept one
            // per day, and picked as the label the closest line of text —
            // i.e. the CATEGORY of the previous operation.
            if info.isDateOnlyLine, info.amounts.isEmpty {
                let consumedBefore = lastConsumed
                let emitted = collectUnderDateHeader(infos: infos, headerIndex: index,
                                                     date: date, lastConsumed: &lastConsumed)
                if !emitted.isEmpty {
                    results.append(contentsOf: emitted)
                    continue
                }
                // Nothing under the header: fall back to the classic path.
                lastConsumed = consumedBefore
            }

            var amounts = info.amounts
            var amountLine = index
            var fromColumnLayout = false

            if amounts.isEmpty {
                // Column layout (screenshot OCR): the amount
                // is on a following line, separated from the label and the
                // date. We never cross a line carrying another date: it
                // would already be the next operation.
                var cursor = index + 1
                while cursor < infos.count, cursor <= index + 3 {
                    let next = infos[cursor]
                    if next.hasDate { break }
                    if !next.amounts.isEmpty, !next.isSummary {
                        amounts = next.amounts
                        amountLine = cursor
                        fromColumnLayout = true
                        break
                    }
                    cursor += 1
                }
            }
            guard let first = amounts.first else { continue }

            var confidence = 0.9
            // ⚠️ Several amounts on the line = column layout
            // (DEBIT | CREDIT | BALANCE). The FIRST is the operation's
            // amount in every layout observed: on a debit line the
            // credit column is empty, and vice versa, while the running
            // balance always comes last. Taking the last one would
            // import the account balance instead.
            if amounts.count > 1 { confidence -= 0.15 }

            // A pure date line has no label, even when a fragment of the
            // date word survives ("Yesterday", "Jul 2") — otherwise the
            // operation's label becomes "Yesterday".
            var label = info.isDateOnlyLine ? "" : info.residual
            var labelFromBackward = false
            if fromColumnLayout {
                // The anchor line only carried a date: the label is
                // above it (every observed app screenshot places it there).
                if label.isEmpty {
                    label = backwardLabel(infos: infos, before: index, notBefore: lastConsumed)
                    labelFromBackward = !label.isEmpty
                }
            } else {
                // Tabular layout: a long label can overflow onto the
                // following lines, which then carry neither date nor
                // amount. With no date on those lines, there's no risk of
                // stealing the next operation's label.
                var cursor = amountLine + 1
                var appended = 0
                while cursor < infos.count, appended < 2 {
                    let next = infos[cursor]
                    guard !next.hasDate, next.amounts.isEmpty,
                          !next.isSummary, !next.residual.isEmpty else { break }
                    label = label.isEmpty ? next.residual : label + " " + next.residual
                    amountLine = cursor
                    appended += 1
                    cursor += 1
                }
                if label.isEmpty {
                    label = backwardLabel(infos: infos, before: index, notBefore: lastConsumed)
                    labelFromBackward = !label.isEmpty
                }
            }

            label = cleanLabel(label)
            // No label = a disguised summary line (carried-over balance,
            // unnamed subtotal). Better to import nothing.
            guard !label.isEmpty else { continue }

            let hint = detectPaymentType(in: label)
            let signed = resolveSign(magnitude: first.value,
                                     explicit: first.isSignExplicit,
                                     label: label)
            if !first.isSignExplicit { confidence -= 0.15 }
            if labelFromBackward { confidence -= 0.05 }

            results.append(ExtractedBankTransaction(
                date: date,
                amount: signed,
                label: label,
                paymentTypeHint: hint,
                isSignExplicit: first.isSignExplicit,
                confidence: max(0.3, confidence)
            ))
            lastConsumed = max(index, amountLine)
        }
        return results
    }

    /// Extracts EVERY operation grouped under a date header, up to
    /// the next header.
    ///
    /// ⚠️ A block's label is its FIRST line of text (the merchant): the
    /// following ones are the app's category or subtitle ("Grocery
    /// store", "Café / games / tobacco"). Taking the one closest to the
    /// amount would always give the category instead of the merchant.
    private static func collectUnderDateHeader(infos: [LineInfo],
                                               headerIndex: Int,
                                               date: String,
                                               lastConsumed: inout Int) -> [ExtractedBankTransaction] {
        var results: [ExtractedBankTransaction] = []
        var pendingLabel = ""
        var cursor = headerIndex + 1
        // ⚠️ We consume ONLY up to the last amount emitted. The
        // text lines that follow already belong to the next block:
        // marking them consumed would rob it of its label
        // (a backward window bounded by `lastConsumed`) in the layout
        // where each operation carries its own date, and the
        // operation would then be lost.
        var consumedUpTo = headerIndex

        while cursor < infos.count {
            let line = infos[cursor]
            // Another date opens the next day.
            if line.hasDate { break }
            if line.isSummary { cursor += 1; continue }

            if let token = line.amounts.first {
                var label = pendingLabel
                var fromBackward = false
                if label.isEmpty {
                    // Reverse layout (merchant ABOVE the date):
                    // this is the case for apps that date each operation.
                    label = backwardLabel(infos: infos, before: headerIndex, notBefore: lastConsumed)
                    fromBackward = !label.isEmpty
                }
                if let tx = makeTransaction(date: date, token: token,
                                            multipleAmounts: line.amounts.count > 1,
                                            label: label, labelFromBackward: fromBackward) {
                    results.append(tx)
                    consumedUpTo = cursor
                }
                pendingLabel = ""
            } else if pendingLabel.isEmpty, !line.residual.isEmpty {
                pendingLabel = line.residual
            }
            cursor += 1
        }
        if !results.isEmpty { lastConsumed = consumedUpTo }
        return results
    }

    /// Factory shared by both layouts (date header and tabular).
    private static func makeTransaction(date: String,
                                        token: AmountToken,
                                        multipleAmounts: Bool,
                                        label: String,
                                        labelFromBackward: Bool) -> ExtractedBankTransaction? {
        let cleaned = cleanLabel(label)
        // No label = a disguised summary line: better to import
        // nothing than an anonymous operation.
        guard !cleaned.isEmpty else { return nil }
        var confidence = 0.9
        if multipleAmounts { confidence -= 0.15 }
        if !token.isSignExplicit { confidence -= 0.15 }
        if labelFromBackward { confidence -= 0.05 }
        return ExtractedBankTransaction(
            date: date,
            amount: resolveSign(magnitude: token.value,
                                explicit: token.isSignExplicit, label: cleaned),
            label: cleaned,
            paymentTypeHint: detectPaymentType(in: cleaned),
            isSignExplicit: token.isSignExplicit,
            confidence: max(0.3, confidence)
        )
    }

    // MARK: - Label

    /// Label looked for ABOVE the anchor, never crossing the
    /// previous block. Takes the closest text line (the one carrying
    /// neither date nor amount), matching the order seen
    /// in screenshots: merchant name, then date, then amount.
    private static func backwardLabel(infos: [LineInfo], before index: Int, notBefore: Int) -> String {
        let lower = max(notBefore + 1, index - 3)
        guard lower < index else { return "" }
        for cursor in stride(from: index - 1, through: lower, by: -1) {
            let candidate = infos[cursor]
            guard !candidate.hasDate, candidate.amounts.isEmpty, !candidate.isSummary else { continue }
            if !candidate.residual.isEmpty { return candidate.residual }
        }
        return ""
    }

    /// Collapses spaces and strips leftover column punctuation.
    private static func cleanLabel(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:;,."))
    }

    // MARK: - Signe

    /// CREDIT keywords. On a column layout, the number carries
    /// no sign at all: only the label's meaning lets us decide.
    private static let creditMarkers = [
        "VIR RECU", "VIREMENT RECU", "VIR DE ", "VIR INST DE", "VIR SEPA RECU",
        "SALAIRE", "REMISE", "REMBOURSEMENT", "RBT ", "VERSEMENT", "DEPOT",
        "INTERETS", "CREDIT ", "AVOIR", "ANNULATION", "ALLOCATION", "PENSION"
    ]

    /// Final sign. Priority to an explicit marker (+/− attached to the
    /// amount), then to keywords, then expense — the vast majority of
    /// lines on a personal statement. AI reconciliation only overrides this
    /// choice when it was NOT explicit (see `isSignExplicit`).
    private static func resolveSign(magnitude: Double, explicit: Bool, label: String) -> Double {
        if explicit { return magnitude }
        let upper = label.uppercased()
        let isCredit = creditMarkers.contains { upper.contains($0) }
        return isCredit ? abs(magnitude) : -abs(magnitude)
    }

    // MARK: - Type de paiement

    /// Payment type inferred from the label, `nil` if no marker
    /// recognized. Order matters: "PSC PAYMENT" is a card operation, it
    /// must be tested before the generic "PAYMENT".
    static func detectPaymentType(in label: String) -> String? {
        let upper = " " + label.uppercased() + " "
        let table: [(markers: [String], type: String)] = [
            (["RETRAIT", "DAB ", "DISTRIB"], "RETRAIT"),
            (["CHEQUE", " CHQ", "CHQ "], "CHEQUE"),
            (["CARTE ", " CB ", "PAIEMENT PSC", "PAIEMENT CB", "ACHAT CB", "PAYWEB"], "CB"),
            (["PRLV", "PRELEVEMENT", "PRELV"], "PRELEVEMENT"),
            (["VIR ", "VIREMENT", "VIRT "], "VIREMENT")
        ]
        for (markers, type) in table where markers.contains(where: { upper.contains($0) }) {
            return type
        }
        return nil
    }

    // MARK: - Analyzing a line

    private struct LineInfo {
        let dateHit: DateHit?
        let amounts: [AmountToken]
        /// Line stripped of the anchor date and of amounts: the base
        /// of the label.
        let residual: String
        let isSummary: Bool
        /// The line carries ONLY the date (down to punctuation).
        /// That's the condition for accepting a yearless date as an anchor:
        /// in "CARD 01/07 CARREFOUR", "01/07" is the card operation's
        /// date, not the statement's — the real date is elsewhere.
        let isDateOnlyLine: Bool

        var hasDate: Bool { dateHit != nil }

        init(raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let hit = BankStatementExtractor.detectDate(in: trimmed)
            self.dateHit = hit
            // ⚠️ Amounts are looked for in text WITHOUT dates. Otherwise
            // "07.02.2026" is read as the amount 7.02: the amount pattern
            // accepts a decimal point, and a dotted date is a perfect
            // substring of it.
            let dateless = BankStatementExtractor.strippingDates(
                BankStatementExtractor.normalizingSpaces(trimmed)
            )
            let tokens = BankStatementExtractor.amountTokens(in: dateless)
            self.amounts = tokens
            var residual = dateless
            for token in tokens.reversed() {
                residual = residual.replacingCharacters(in: token.range, with: " ")
            }
            self.residual = BankStatementExtractor.cleanLabel(residual)
            self.isSummary = BankStatementExtractor.isSummaryLine(trimmed)
            self.isDateOnlyLine = hit != nil && BankStatementExtractor.isDateOnly(trimmed)
        }
    }

    // MARK: - Dates : formes reconnues

    /// A date found on a line.
    enum DateHit {
        /// Full date (day, month AND year): can be anchored anywhere in the
        /// line, including in the middle of a tabular label.
        case complete(String)             // yyyy-MM-dd
        /// Day + month without year ("Jul 2", "07/02"): the year is
        /// inferred, and the line must be a pure date line.
        case dayMonth(day: Int, month: Int)
        /// "Today" / "Yesterday" — ubiquitous at the top of banking app
        /// lists.
        case relative(daysAgo: Int)
    }

    /// Resolves a line's date to `yyyy-MM-dd`, or `nil` if the line
    /// carries none usable.
    private static func resolvedDate(_ info: LineInfo, reference: Date) -> String? {
        switch info.dateHit {
        case .complete(let iso):
            return iso
        case .dayMonth(let day, let month):
            guard info.isDateOnlyLine else { return nil }
            return isoDate(day: day, month: month, reference: reference)
        case .relative(let daysAgo):
            guard info.isDateOnlyLine else { return nil }
            guard let shifted = gregorian.date(byAdding: .day, value: -daysAgo, to: reference) else { return nil }
            let c = gregorian.dateComponents([.year, .month, .day], from: shifted)
            guard let y = c.year, let m = c.month, let d = c.day else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        case nil:
            return nil
        }
    }

    private static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal
    }()

    /// Year inferred for a bare day+month: the reference's year, unless the
    /// resulting date would be IN THE FUTURE — a statement is always
    /// historical, so "December 28" read on January 3rd means the
    /// previous year.
    private static func isoDate(day: Int, month: Int, reference: Date) -> String? {
        let c = gregorian.dateComponents([.year, .month, .day], from: reference)
        guard let refYear = c.year, let refMonth = c.month, let refDay = c.day else { return nil }
        let year = (month, day) > (refMonth, refDay) ? refYear - 1 : refYear
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Detects a line's date, from the most reliable form to the least
    /// constrained one.
    static func detectDate(in line: String) -> DateHit? {
        // 1) Full numeric date (dd/MM/yyyy, yyyy-MM-dd…) — the safest.
        if let iso = InvestmentStatementExtractor.firstDate(in: line) {
            return .complete(iso)
        }
        // 2) Spelled-out date, with or without a year ("June 12 2026",
        //    "Jul 2", "2 July").
        if let named = monthNameDate(in: line) {
            if let year = named.year {
                return .complete(String(format: "%04d-%02d-%02d", year, named.month, named.day))
            }
            return .dayMonth(day: named.day, month: named.month)
        }
        // 3) Banking-app relative keywords.
        //
        // ⚠️ WHOLE-WORD comparison only, never a substring: "yesterday" is
        // contained inside "vesterday"-like false positives in other locales…
        let words = Set(tokens(of: line))
        if !words.isDisjoint(with: ["aujourd", "today"]) { return .relative(daysAgo: 0) }
        if !words.isDisjoint(with: ["hier", "yesterday"]) { return .relative(daysAgo: 1) }
        // 4) Numeric day/month without a year ("07/02").
        if let dm = numericDayMonth(in: line) {
            return .dayMonth(day: dm.day, month: dm.month)
        }
        return nil
    }

    /// FR and EN month names, long and abbreviated forms. Keys are
    /// "folded" (no accents, lowercase): OCR often renders "aout" or
    /// "fevrier" (French, missing accents).
    private static let monthsByName: [String: Int] = {
        let table: [(Int, [String])] = [
            (1,  ["janvier", "janv", "jan", "january"]),
            (2,  ["fevrier", "fevr", "fev", "february", "feb"]),
            (3,  ["mars", "march", "mar"]),
            (4,  ["avril", "avr", "april", "apr"]),
            (5,  ["mai", "may"]),
            (6,  ["juin", "june", "jun"]),
            (7,  ["juillet", "juil", "july", "jul"]),
            (8,  ["aout", "august", "aug"]),
            (9,  ["septembre", "sept", "sep", "september"]),
            (10, ["octobre", "oct", "october"]),
            (11, ["novembre", "nov", "november"]),
            (12, ["decembre", "dec", "december"])
        ]
        var out: [String: Int] = [:]
        for (number, names) in table {
            for name in names { out[name] = number }
        }
        return out
    }()

    /// "2 juil.", "12 juin 2026", "Jul 2", "July 2, 2026".
    static func monthNameDate(in line: String) -> (day: Int, month: Int, year: Int?)? {
        let folded = line
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        // Words are split on punctuation AND spaces: "2 juil."
        // as well as "July 2, 2026".
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return nil }

        for (index, word) in words.enumerated() {
            guard let month = monthsByName[word] else { continue }
            // Day BEFORE (FR: "2 juil.") or AFTER (EN: "Jul 2").
            var day: Int?
            if index > 0, let d = Int(words[index - 1]), (1...31).contains(d) { day = d }
            if day == nil, index + 1 < words.count,
               let d = Int(words[index + 1]), (1...31).contains(d) { day = d }
            guard let day else { continue }

            // Year: a plausible 4-digit number anywhere on the line.
            let year = words.compactMap(Int.init).first { (1900...2200).contains($0) }
            return (day, month, year)
        }
        return nil
    }

    /// "02/07" or "02-07" — bare day/month, FR convention (day first).
    private static let numericDayMonthRegex = try? NSRegularExpression(
        pattern: "\\b(\\d{1,2})[/-](\\d{1,2})\\b")

    static func numericDayMonth(in line: String) -> (day: Int, month: Int)? {
        guard let regex = numericDayMonthRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let dayRange = Range(match.range(at: 1), in: line),
              let monthRange = Range(match.range(at: 2), in: line),
              let day = Int(line[dayRange]), let month = Int(line[monthRange]),
              (1...31).contains(day), (1...12).contains(month)
        else { return nil }
        return (day, month)
    }

    /// Normalizes a date PRODUCED BY A MODEL to `yyyy-MM-dd`.
    ///
    /// ⚠️ A model asked for `yyyy-MM-dd` doesn't always honor it:
    /// on a banking-app screenshot, the year is written NOWHERE, and it
    /// then produces forms like "22-07-00" or "22/07". Rejecting these
    /// lines used to throw away the WHOLE extraction even though the day and
    /// month were correct — symptom: "no operations recognized" with a JSON
    /// right there under our eyes.
    ///
    /// FR convention (like the rest of the engine): day first when the
    /// order is ambiguous. A missing or implausible year is inferred from
    /// `referenceDate`, with the same rule as elsewhere — a date that would
    /// fall in the future belongs to the previous year.
    static func normalizeDate(_ raw: String, referenceDate: Date = Date()) -> String? {
        let parts = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }

        // Explicit year: the 4-digit component, wherever it is.
        let explicitYear = parts.first { (1900...2200).contains($0) }
        let rest = parts.filter { !(1900...2200).contains($0) }
        guard rest.count >= 2 else { return nil }

        let day: Int, month: Int
        if rest[0] > 12, rest[1] <= 12 {
            day = rest[0]; month = rest[1]          // 22-07 → jour-mois
        } else if rest[0] <= 12, rest[1] > 12 {
            day = rest[1]; month = rest[0]          // 07-22 → mois-jour (anglo)
        } else {
            day = rest[0]; month = rest[1]          // ambigu → convention FR
        }
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }

        if let year = explicitYear {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return isoDate(day: day, month: month, reference: referenceDate)
    }

    /// Words of a line, without accents or case, punctuation stripped.
    static func tokens(of line: String) -> [String] {
        line.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let relativeKeywords: Set<String> = [
        "aujourd", "hui", "hier", "today", "yesterday"
    ]

    /// True if the line carries ONLY a date, down to the date words and
    /// punctuation: "2 juil.", "Yesterday", "02/07", "12 juin 2026".
    ///
    /// This is the condition that allows a yearless date to serve as an
    /// anchor. Without it, the "01/07" in "CARD 01/07 CARREFOUR" (the
    /// card operation's date, not the statement's) would open a fake operation.
    static func isDateOnly(_ line: String) -> Bool {
        // Full numeric dates have already been stripped by `strippingDates`.
        let remaining = tokens(of: strippingDates(line)).filter { token in
            if monthsByName[token] != nil { return false }
            if relativeKeywords.contains(token) { return false }
            // Numbers belonging to a date: the day, or the year.
            if let n = Int(token), (1...31).contains(n) || (1900...2200).contains(n) { return false }
            return true
        }
        return remaining.isEmpty
    }

    /// Statement summary lines: they carry a date AND an amount
    /// without being operations.
    ///
    /// ⚠️ No marker can be a bare "TOTAL": TOTALENERGIES is a
    /// common French merchant on a bank statement. Every marker is
    /// therefore a full phrase.
    private static let summaryMarkers = [
        "ANCIEN SOLDE", "NOUVEAU SOLDE", "SOLDE PRECEDENT", "SOLDE PRÉCÉDENT",
        "SOLDE CREDITEUR", "SOLDE CRÉDITEUR", "SOLDE DEBITEUR", "SOLDE DÉBITEUR",
        "SOLDE AU ", "SOLDE INITIAL", "SOLDE FINAL", "TOTAL DES", "TOTAUX",
        "SOUS-TOTAL", "REPORT A NOUVEAU", "REPORT À NOUVEAU", "TOTAL DEBIT", "TOTAL CREDIT"
    ]

    static func isSummaryLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return summaryMarkers.contains { upper.contains($0) }
    }

    // MARK: - Dates

    /// Long forms first (they consume the whole token), then short
    /// forms with a SLASH or DASH only.
    ///
    /// ⚠️ Never add a dot to the short forms: "12.50" would match
    /// it and every decimal-point amount would vanish from the analyzed text.
    private static let datePatternsToStrip: [NSRegularExpression?] = [
        try? NSRegularExpression(pattern: "\\b\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{2,4}\\b"),
        try? NSRegularExpression(pattern: "\\b\\d{4}[/.-]\\d{1,2}[/.-]\\d{1,2}\\b"),
        try? NSRegularExpression(pattern: "\\b\\d{1,2}[/-]\\d{1,2}\\b")
    ]

    static func strippingDates(_ text: String) -> String {
        var out = text
        for regex in datePatternsToStrip {
            guard let regex else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: " ")
        }
        return out
    }

    // MARK: - Montants

    struct AmountToken {
        let value: Double
        /// The token had a "+" or a "−" attached.
        let isSignExplicit: Bool
        let range: Range<String.Index>
    }

    /// Same discipline as `InvestmentStatementExtractor.signedAmount`: an
    /// amount carries cents OR a currency. A bare integer cannot be
    /// an amount, otherwise a phone number or an IBAN would become one.
    /// Difference: we return ALL tokens on the line, to tell apart the
    /// operation column from the balance column.
    ///
    /// Two branches, and the split is what guarantees non-invention:
    ///   • a decimal part is present → currency is optional;
    ///   • a bare integer → currency is REQUIRED.
    ///
    /// ⚠️ The thousands group must be spelled out explicitly
    /// (`\d{1,3}(?:[ .,]\d{3})+`). A permissive `[\d ]*` only covers
    /// the space: "1,234.56" would be read as "234.56", an amount
    /// short its thousand — silently, since the line stayed valid.
    private static let amountRegex = try? NSRegularExpression(pattern:
        "[+-]?(?:\\d{1,3}(?:[ .,]\\d{3})+|\\d+)[.,]\\d{1,2}(?![\\d])\\s*(?:€|EUR|\\$|USD)?"
        + "|"
        + "[+-]?(?:\\d{1,3}(?:[ .,]\\d{3})+|\\d+)(?![\\d.,])\\s*(?:€|EUR|\\$|USD)")

    /// Replaces non-breaking spaces with plain spaces.
    ///
    /// ⚠️ Apply BEFORE `amountTokens`, never inside it: the `Range`s it
    /// returns index into the exact string that was passed in. Normalizing
    /// inside would produce indices pointing into a different `String`
    /// instance than the caller's — invalid indices at slicing time.
    static func normalizingSpaces(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func amountTokens(in cleaned: String) -> [AmountToken] {
        guard let regex = amountRegex else { return [] }
        var tokens: [AmountToken] = []
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        regex.enumerateMatches(in: cleaned, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: cleaned) else { return }
            let raw = String(cleaned[r])
            let stripped = raw
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "EUR", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "USD", with: "")
                // ⚠️ The pattern's trailing `\s*` swallows the newline: without
                // this trim, `Double("+1.70\n")` returns nil and the amount is
                // silently lost.
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = InvestmentStatementExtractor.parseNumber(
                stripped.replacingOccurrences(of: " ", with: "")
            ) else { return }
            let explicit = stripped.hasPrefix("+") || stripped.hasPrefix("-")
            tokens.append(AmountToken(value: value, isSignExplicit: explicit, range: r))
        }
        return tokens
    }
}
