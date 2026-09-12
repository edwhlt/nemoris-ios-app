import Foundation

// MARK: - Structured statements: CAMT.053 (ISO 20022) and OFX / QFX
//
// PURE engine — testable via `run_import_pipeline_tests.sh`.
//
// ─── Why these formats NEVER go through AI ──────────────────────────────────
//
// Unlike a PDF or a screenshot, these files NAME their fields:
// the amount is in `<Amt>`, the direction in `<CdtDbtInd>`, the date in
// `<BookgDt>`. There's nothing to interpret. Sending them to a model would be
// both slower, costlier and LESS reliable than reading the tags — and
// would introduce a probabilistic extraction where the data is exact.
//
// ─── Two formats, one reader ────────────────────────────────────────────────
//
// CAMT.053 is strict XML. OFX 1.x is SGML with unclosed tags, OFX
// 2.0 is XML. They share the same role (a statement of operations exported by
// the bank) and the same output, so a single entry point that recognizes
// the dialect rather than two paths nothing would tie together.

struct LedgerXMLError: Error, Equatable {
    let reason: String
}

enum LedgerXMLReader {

    /// Dialecte reconnu.
    enum Dialect: Equatable {
        case camt053
        case ofx
    }

    // MARK: - Entry point

    static func parse(data: Data) -> Result<[ImportPayload], LedgerXMLError> {
        guard let text = ImportFormatSniffer.decodeText(data) else {
            return .failure(LedgerXMLError(reason: "encodage du fichier illisible"))
        }
        return parse(text: text)
    }

    static func parse(text: String) -> Result<[ImportPayload], LedgerXMLError> {
        switch detectDialect(text) {
        case .camt053: return CAMT053Parser.parse(text)
        case .ofx:     return OFXParser.parse(text)
        case nil:
            return .failure(LedgerXMLError(
                reason: "format XML non reconnu (ni CAMT.053 ni OFX)"))
        }
    }

    /// Recognition by content, never by extension: a bank happily
    /// exports an OFX named `.xml` and a CAMT named `.txt`.
    static func detectDialect(_ text: String) -> Dialect? {
        let head = String(text.prefix(4096)).uppercased()
        if head.contains("OFXHEADER") || head.contains("<OFX>") || head.contains("<OFX ") {
            return .ofx
        }
        // `BkToCstmrStmt` is the root specific to a statement (camt.053); the second
        // marker covers files whose namespace carries the version.
        if head.contains("BKTOCSTMRSTMT") || head.contains("CAMT.053") { return .camt053 }
        return nil
    }
}

// MARK: - CAMT.053 (ISO 20022)

/// Structure used:
/// `Document / BkToCstmrStmt / Stmt / Ntry` — one entry per `Ntry`.
///
/// Fields kept per entry:
///   • `Amt`         → amount, ALWAYS positive (`Ccy` attribute for the currency)
///   • `CdtDbtInd`   → `CRDT` (credit) or `DBIT` (debit) — THIS carries the sign
///   • `BookgDt/Dt`  → booking date, else `ValDt/Dt` (value date)
///   • label         → `RmtInf/Ustrd`, else `AddtlNtryInf`, else the counterparty's name
enum CAMT053Parser {

    static func parse(_ text: String) -> Result<[ImportPayload], LedgerXMLError> {
        guard let data = text.data(using: .utf8) else {
            return .failure(LedgerXMLError(reason: "conversion UTF-8 impossible"))
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let line = parser.lineNumber
            return .failure(LedgerXMLError(reason: "XML invalide (ligne \(line))"))
        }
        return .success(delegate.payloads)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var payloads: [ImportPayload] = []

        /// Stack of open elements: this is what lets us tell apart a
        /// counterparty's `<Nm>` from an account holder's `<Nm>`, or an
        /// entry date from a statement header date — the same tag names
        /// are used in several places in the tree.
        private var path: [String] = []
        private var text = ""

        private var entry = Entry()

        private struct Entry {
            var amount: Double?
            var currency = "EUR"
            var isCredit: Bool?
            var bookingDate: String?
            var valueDate: String?
            var remittance: [String] = []
            var additionalInfo: String?
            var counterparty: String?

            var isEmpty: Bool { amount == nil }
        }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let element = localName(name)
            path.append(element)
            text = ""
            if element == "Ntry" { entry = Entry() }
            // The currency is an ATTRIBUTE of the amount, not an element.
            if element == "Amt", insideEntry, let ccy = attributes["Ccy"] {
                entry.currency = ccy
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let element = localName(name)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                if !path.isEmpty { path.removeLast() }
                text = ""
            }

            guard insideEntry else { return }

            switch element {
            case "Amt":
                // ⚠️ Only the entry's OWN amount. An entry often carries
                // `<Amt>`s nested inside its details (original amount before FX,
                // fees): taking them would replace the real amount with the
                // last one seen.
                if path.suffix(2).first == "Ntry" { entry.amount = Double(value) }
            case "CdtDbtInd":
                if path.suffix(2).first == "Ntry" { entry.isCredit = (value.uppercased() == "CRDT") }
            case "Dt", "DtTm":
                // ISO 8601: keep only the date part.
                let day = String(value.prefix(10))
                if path.contains("BookgDt") { entry.bookingDate = day }
                else if path.contains("ValDt") { entry.valueDate = day }
            case "Ustrd":
                if !value.isEmpty { entry.remittance.append(value) }
            case "AddtlNtryInf":
                if !value.isEmpty { entry.additionalInfo = value }
            case "Nm":
                // Counterparty name: the creditor's on a debit,
                // the debtor's on a credit.
                if path.contains("RltdPties"), entry.counterparty == nil, !value.isEmpty {
                    entry.counterparty = value
                }
            case "Ntry":
                flush()
            default:
                break
            }
        }

        private var insideEntry: Bool { path.contains("Ntry") }

        private func flush() {
            defer { entry = Entry() }
            guard !entry.isEmpty,
                  let amount = entry.amount,
                  let date = entry.bookingDate ?? entry.valueDate else { return }

            // The sign comes from `CdtDbtInd`, never from the number: CAMT ALWAYS
            // writes a positive amount. With no indicator, fall back to the
            // app's default convention (expense) rather than inventing one.
            let isCredit = entry.isCredit ?? false
            let label = [entry.remittance.joined(separator: " "),
                         entry.additionalInfo,
                         entry.counterparty]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                ?? "Opération"

            payloads.append(.transaction(ExtractedBankTransaction(
                date: date,
                amount: isCredit ? abs(amount) : -abs(amount),
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                paymentTypeHint: nil,
                // The direction is DECLARED by the format, not inferred from a label:
                // it's the most reliable information we can have.
                isSignExplicit: true,
                confidence: 1.0
            )))
        }
    }
}

// MARK: - OFX / QFX

/// OFX 1.x isn't XML: its tags aren't closed
/// (`<TRNAMT>-42.50` followed by a newline). OFX 2.0 is. A tolerant
/// tokenizer absorbs both — and nothing else would, `XMLParser`
/// rejecting the 1.x dialect outright, which remains the most common.
enum OFXParser {

    static func parse(_ text: String) -> Result<[ImportPayload], LedgerXMLError> {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else {
            return .failure(LedgerXMLError(reason: "aucune balise OFX exploitable"))
        }

        var payloads: [ImportPayload] = []
        payloads += bankTransactions(tokens)
        payloads += investmentOrders(tokens)

        return .success(payloads)
    }

    // MARK: Tokenizer

    enum Token: Equatable {
        case open(String)
        case close(String)
        /// A tag carrying a value on the same line: `<TRNAMT>-42.50`.
        case value(tag: String, text: String)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while let open = text[index...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { break }
            let rawTag = String(text[text.index(after: open)..<close])
            index = text.index(after: close)

            // SGML headers and XML declarations — neither is a
            // data tag.
            if rawTag.hasPrefix("?") || rawTag.hasPrefix("!") { continue }

            if rawTag.hasPrefix("/") {
                tokens.append(.close(String(rawTag.dropFirst()).uppercased()))
                continue
            }
            let tag = rawTag
                .split(separator: " ").first.map(String.init)?.uppercased() ?? rawTag.uppercased()

            // Text up to the next tag: that's the value in OFX 1.x, and
            // it's also the value in OFX 2.0, simply followed by `</TAG>`.
            let nextOpen = text[index...].firstIndex(of: "<") ?? text.endIndex
            let value = text[index..<nextOpen].trimmingCharacters(in: .whitespacesAndNewlines)

            if value.isEmpty {
                tokens.append(.open(tag))
                continue
            }

            tokens.append(.value(tag: tag, text: value))
            index = nextOpen

            // ⚠️ In OFX 2.0 (well-formed XML), the value is followed by its
            // closing tag. It MUST be consumed here: passed through as-is, it
            // would reach `blocks` as the close of a block never opened
            // — the depth counter would go to -1 and the current block would be
            // settled at the first field. Symptoms measured: an OFX 2.0 statement
            // returned NO operations at all, and a broker's OFX lost every
            // order whose date is inside a nested `<INVTRAN>`.
            if let closeOpen = text[index...].firstIndex(of: "<"),
               let closeEnd = text[closeOpen...].firstIndex(of: ">") {
                let closing = String(text[text.index(after: closeOpen)..<closeEnd])
                if closing.hasPrefix("/"),
                   String(closing.dropFirst()).uppercased() == tag {
                    index = text.index(after: closeEnd)
                }
            }
        }
        return tokens
    }

    // MARK: Bank operations

    /// `<STMTTRN>` : TRNTYPE, DTPOSTED, TRNAMT, NAME / MEMO, FITID.
    static func bankTransactions(_ tokens: [Token]) -> [ImportPayload] {
        blocks(named: "STMTTRN", in: tokens).compactMap { fields in
            guard let rawAmount = fields["TRNAMT"],
                  let amount = Double(rawAmount.replacingOccurrences(of: ",", with: ".")),
                  amount != 0,
                  let rawDate = fields["DTPOSTED"],
                  let date = normalizedDate(rawDate) else { return nil }

            // NAME is the counterparty, MEMO the free-text detail. The first is
            // closer to the expected label; we append the second when
            // it adds something else.
            let name = fields["NAME"] ?? ""
            let memo = fields["MEMO"] ?? ""
            let label: String
            if name.isEmpty { label = memo }
            else if memo.isEmpty || memo == name { label = name }
            else { label = "\(name) — \(memo)" }
            guard !label.isEmpty else { return nil }

            return .transaction(ExtractedBankTransaction(
                date: date,
                // ⚠️ In OFX the sign is CARRIED BY THE NUMBER (unlike
                // CAMT): a debit is already negative. Forcing it based on TRNTYPE
                // would flip refunds, which are positive `DEBIT`s.
                amount: amount,
                label: label,
                paymentTypeHint: paymentHint(fields["TRNTYPE"]),
                isSignExplicit: true,
                confidence: 1.0
            ))
        }
    }

    /// Stock market orders — a broker's OFX carries an `INVSTMTMSGSRSV1`.
    static func investmentOrders(_ tokens: [Token]) -> [ImportPayload] {
        var results: [ImportPayload] = []

        func collect(_ blockName: String, orderType: String) {
            for fields in blocks(named: blockName, in: tokens) {
                guard let rawDate = fields["DTTRADE"] ?? fields["DTSETTLE"],
                      let date = normalizedDate(rawDate) else { continue }
                let quantity = fields["UNITS"].flatMap(Double.init).map(abs) ?? 0
                let price = fields["UNITPRICE"].flatMap(Double.init) ?? 0
                // A dividend has neither quantity nor price: it's the TOTAL that
                // carries the information, and requiring it like the others would
                // make every income line disappear.
                let total = fields["TOTAL"].flatMap(Double.init).map(abs) ?? 0
                guard quantity > 0 || total > 0 else { continue }

                let isin = fields["UNIQUEID"].flatMap { id in
                    fields["UNIQUEIDTYPE"]?.uppercased() == "ISIN" ? id.uppercased() : nil
                } ?? ""

                results.append(.investmentOrder(ExtractedStatementOrder(
                    orderType: orderType,
                    assetName: fields["SECNAME"] ?? fields["MEMO"] ?? "Titre",
                    isin: isin,
                    ticker: fields["TICKER"] ?? "",
                    quantity: quantity > 0 ? quantity : 1,
                    unitPrice: price > 0 ? price : total,
                    fees: fields["COMMISSION"].flatMap(Double.init).map(abs) ?? 0,
                    executedAt: date,
                    currency: fields["CURSYM"] ?? "EUR",
                    notes: "Import OFX",
                    confidence: 1.0
                )))
            }
        }

        collect("BUYSTOCK", orderType: "BUY")
        collect("BUYMF", orderType: "BUY")
        collect("BUYOTHER", orderType: "BUY")
        collect("SELLSTOCK", orderType: "SELL")
        collect("SELLMF", orderType: "SELL")
        collect("SELLOTHER", orderType: "SELL")
        collect("INCOME", orderType: "DIV")
        return results
    }

    // MARK: Utilities

    /// Flat fields of a named block, nesting included.
    ///
    /// ⚠️ OFX blocks are nested (`<BUYSTOCK><INVBUY><SECID><UNIQUEID>`),
    /// and intermediate levels vary from one producer to another. So we
    /// flatten the whole subtree until the block closes rather than
    /// hardcode an exact path that would break on the first atypical export.
    static func blocks(named target: String, in tokens: [Token]) -> [[String: String]] {
        var results: [[String: String]] = []
        var current: [String: String]?
        var depth = 0

        for token in tokens {
            switch token {
            case .open(let tag):
                if tag == target {
                    current = [:]
                    depth = 0
                } else if current != nil {
                    depth += 1
                }
            case .close(let tag):
                if tag == target {
                    if let fields = current, !fields.isEmpty { results.append(fields) }
                    current = nil
                } else if current != nil {
                    depth -= 1
                    // Unmatched close of a sibling block in SGML: settle
                    // the current block rather than absorb the rest of the file.
                    if depth < 0 {
                        if let fields = current, !fields.isEmpty { results.append(fields) }
                        current = nil
                        depth = 0
                    }
                }
            case .value(let tag, let text):
                // First value wins: on a nested block, the outer
                // level's field is the more specific one.
                if current != nil, current?[tag] == nil { current?[tag] = text }
            }
        }
        return results
    }

    /// `20260722120000.000[-5:EST]` → `2026-07-22`.
    static func normalizedDate(_ raw: String) -> String? {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let stamp = String(digits.prefix(8))
        let year = Int(stamp.prefix(4)) ?? 0
        let month = Int(stamp.dropFirst(4).prefix(2)) ?? 0
        let day = Int(stamp.dropFirst(6).prefix(2)) ?? 0
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func paymentHint(_ type: String?) -> String? {
        switch type?.uppercased() {
        case "POS", "PAYMENT":              return "CB"
        case "XFER", "DIRECTDEP", "DEP":    return "VIREMENT"
        case "DIRECTDEBIT", "REPEATPMT":    return "PRELEVEMENT"
        case "ATM", "CASH":                 return "RETRAIT"
        case "CHECK":                       return "CHEQUE"
        default:                            return nil
        }
    }
}
