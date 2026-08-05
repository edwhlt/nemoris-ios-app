import Foundation

// MARK: - Relevés structurés : CAMT.053 (ISO 20022) et OFX / QFX
//
// Moteur PUR — testable via `run_import_pipeline_tests.sh`.
//
// ─── Pourquoi ces formats ne passent JAMAIS par l'IA ────────────────────────
//
// Contrairement à un PDF ou à une capture, ces fichiers NOMMENT leurs champs :
// le montant est dans `<Amt>`, le sens dans `<CdtDbtInd>`, la date dans
// `<BookgDt>`. Il n'y a rien à interpréter. Les envoyer à un modèle serait à la
// fois plus lent, plus coûteux et MOINS fiable que de lire les balises — et
// introduirait une extraction probabiliste là où la donnée est exacte.
//
// ─── Deux formats, un seul lecteur ─────────────────────────────────────────
//
// CAMT.053 est du XML strict. OFX 1.x est du SGML à balises non fermées, OFX
// 2.0 du XML. Ils partagent le même rôle (un relevé d'opérations exporté par la
// banque) et la même sortie, donc un seul point d'entrée qui reconnaît le
// dialecte plutôt que deux chemins que rien ne relierait.

struct LedgerXMLError: Error, Equatable {
    let reason: String
}

enum LedgerXMLReader {

    /// Dialecte reconnu.
    enum Dialect: Equatable {
        case camt053
        case ofx
    }

    // MARK: - Point d'entrée

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

    /// Reconnaissance par le contenu, jamais par l'extension : une banque
    /// exporte volontiers un OFX nommé `.xml` et un CAMT nommé `.txt`.
    static func detectDialect(_ text: String) -> Dialect? {
        let head = String(text.prefix(4096)).uppercased()
        if head.contains("OFXHEADER") || head.contains("<OFX>") || head.contains("<OFX ") {
            return .ofx
        }
        // `BkToCstmrStmt` est la racine propre au relevé (camt.053) ; le second
        // marqueur couvre les fichiers dont l'espace de noms porte la version.
        if head.contains("BKTOCSTMRSTMT") || head.contains("CAMT.053") { return .camt053 }
        return nil
    }
}

// MARK: - CAMT.053 (ISO 20022)

/// Structure exploitée :
/// `Document / BkToCstmrStmt / Stmt / Ntry` — une écriture par `Ntry`.
///
/// Champs retenus par écriture :
///   • `Amt`         → montant, TOUJOURS positif (attribut `Ccy` pour la devise)
///   • `CdtDbtInd`   → `CRDT` (crédit) ou `DBIT` (débit) — c'est LUI qui porte le signe
///   • `BookgDt/Dt`  → date comptable, sinon `ValDt/Dt` (date de valeur)
///   • libellé       → `RmtInf/Ustrd`, sinon `AddtlNtryInf`, sinon le nom de la contrepartie
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

        /// Pile des éléments ouverts : c'est elle qui permet de distinguer un
        /// `<Nm>` de contrepartie d'un `<Nm>` de titulaire de compte, ou une
        /// date d'écriture d'une date d'en-tête de relevé — les mêmes noms de
        /// balise servent à plusieurs endroits de l'arbre.
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
            // La devise est un ATTRIBUT du montant, pas un élément.
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
                // ⚠️ Uniquement le montant de l'écriture elle-même. Une
                // écriture porte souvent des `<Amt>` imbriqués dans ses détails
                // (montant d'origine avant change, frais) : les prendre
                // remplacerait le montant réel par le dernier vu.
                if path.suffix(2).first == "Ntry" { entry.amount = Double(value) }
            case "CdtDbtInd":
                if path.suffix(2).first == "Ntry" { entry.isCredit = (value.uppercased() == "CRDT") }
            case "Dt", "DtTm":
                // ISO 8601 : on ne garde que la partie date.
                let day = String(value.prefix(10))
                if path.contains("BookgDt") { entry.bookingDate = day }
                else if path.contains("ValDt") { entry.valueDate = day }
            case "Ustrd":
                if !value.isEmpty { entry.remittance.append(value) }
            case "AddtlNtryInf":
                if !value.isEmpty { entry.additionalInfo = value }
            case "Nm":
                // Nom de la contrepartie : celui du créancier sur un débit,
                // celui du débiteur sur un crédit.
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

            // Le signe vient de `CdtDbtInd`, jamais du nombre : CAMT écrit
            // TOUJOURS un montant positif. Sans indicateur, on retient la
            // convention par défaut de l'app (dépense) plutôt que d'inventer.
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
                // Le sens est DÉCLARÉ par le format, pas déduit d'un libellé :
                // c'est l'information la plus sûre qu'on puisse avoir.
                isSignExplicit: true,
                confidence: 1.0
            )))
        }
    }
}

// MARK: - OFX / QFX

/// OFX 1.x n'est pas du XML : ses balises ne sont pas fermées
/// (`<TRNAMT>-42.50` suivi d'une nouvelle ligne). OFX 2.0 l'est. Un tokenizer
/// tolérant absorbe les deux — et rien d'autre ne le ferait, `XMLParser`
/// rejetant en bloc le dialecte 1.x, qui reste le plus répandu.
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
        /// Balise portant une valeur sur la même ligne : `<TRNAMT>-42.50`.
        case value(tag: String, text: String)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while let open = text[index...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { break }
            let rawTag = String(text[text.index(after: open)..<close])
            index = text.index(after: close)

            // En-têtes SGML et déclarations XML — ni l'un ni l'autre n'est une
            // balise de données.
            if rawTag.hasPrefix("?") || rawTag.hasPrefix("!") { continue }

            if rawTag.hasPrefix("/") {
                tokens.append(.close(String(rawTag.dropFirst()).uppercased()))
                continue
            }
            let tag = rawTag
                .split(separator: " ").first.map(String.init)?.uppercased() ?? rawTag.uppercased()

            // Texte jusqu'à la balise suivante : c'est la valeur en OFX 1.x, et
            // c'est aussi la valeur en OFX 2.0, simplement suivie de `</TAG>`.
            let nextOpen = text[index...].firstIndex(of: "<") ?? text.endIndex
            let value = text[index..<nextOpen].trimmingCharacters(in: .whitespacesAndNewlines)

            if value.isEmpty {
                tokens.append(.open(tag))
                continue
            }

            tokens.append(.value(tag: tag, text: value))
            index = nextOpen

            // ⚠️ En OFX 2.0 (XML bien formé), la valeur est suivie de sa balise
            // fermante. Il FAUT la consommer ici : émise telle quelle, elle
            // arriverait à `blocks` comme la fermeture d'un bloc jamais ouvert
            // — le compteur de profondeur passait à -1 et le bloc courant était
            // soldé au premier champ. Symptômes mesurés : un relevé OFX 2.0 ne
            // rendait AUCUNE opération, et un OFX de courtier perdait tous les
            // ordres dont la date est dans un `<INVTRAN>` imbriqué.
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

    // MARK: Opérations bancaires

    /// `<STMTTRN>` : TRNTYPE, DTPOSTED, TRNAMT, NAME / MEMO, FITID.
    static func bankTransactions(_ tokens: [Token]) -> [ImportPayload] {
        blocks(named: "STMTTRN", in: tokens).compactMap { fields in
            guard let rawAmount = fields["TRNAMT"],
                  let amount = Double(rawAmount.replacingOccurrences(of: ",", with: ".")),
                  amount != 0,
                  let rawDate = fields["DTPOSTED"],
                  let date = normalizedDate(rawDate) else { return nil }

            // NAME est la contrepartie, MEMO le détail libre. Le premier est
            // plus proche du libellé attendu ; on complète avec le second quand
            // il apporte autre chose.
            let name = fields["NAME"] ?? ""
            let memo = fields["MEMO"] ?? ""
            let label: String
            if name.isEmpty { label = memo }
            else if memo.isEmpty || memo == name { label = name }
            else { label = "\(name) — \(memo)" }
            guard !label.isEmpty else { return nil }

            return .transaction(ExtractedBankTransaction(
                date: date,
                // ⚠️ En OFX le signe est PORTÉ PAR LE NOMBRE (contrairement à
                // CAMT) : un débit est déjà négatif. Le forcer d'après TRNTYPE
                // inverserait les remboursements, qui sont des `DEBIT` positifs.
                amount: amount,
                label: label,
                paymentTypeHint: paymentHint(fields["TRNTYPE"]),
                isSignExplicit: true,
                confidence: 1.0
            ))
        }
    }

    /// Ordres de bourse — un OFX de courtier porte un `INVSTMTMSGSRSV1`.
    static func investmentOrders(_ tokens: [Token]) -> [ImportPayload] {
        var results: [ImportPayload] = []

        func collect(_ blockName: String, orderType: String) {
            for fields in blocks(named: blockName, in: tokens) {
                guard let rawDate = fields["DTTRADE"] ?? fields["DTSETTLE"],
                      let date = normalizedDate(rawDate) else { continue }
                let quantity = fields["UNITS"].flatMap(Double.init).map(abs) ?? 0
                let price = fields["UNITPRICE"].flatMap(Double.init) ?? 0
                // Un dividende n'a ni quantité ni cours : c'est le TOTAL qui
                // porte l'information, et l'exiger comme les autres ferait
                // disparaître toutes les lignes de revenu.
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

    // MARK: Utilitaires

    /// Champs à plat d'un bloc nommé, imbrications comprises.
    ///
    /// ⚠️ Les blocs OFX sont emboîtés (`<BUYSTOCK><INVBUY><SECID><UNIQUEID>`),
    /// et les niveaux intermédiaires varient d'un producteur à l'autre. On
    /// aplatit donc tout le sous-arbre jusqu'à la fermeture du bloc plutôt que
    /// de coder un chemin exact qui casserait au premier export atypique.
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
                    // Fermeture non appariée d'un bloc frère en SGML : on solde
                    // le bloc courant plutôt que d'absorber la suite du fichier.
                    if depth < 0 {
                        if let fields = current, !fields.isEmpty { results.append(fields) }
                        current = nil
                        depth = 0
                    }
                }
            case .value(let tag, let text):
                // Première valeur gagnante : sur un bloc imbriqué, le champ du
                // niveau extérieur est le plus spécifique.
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
