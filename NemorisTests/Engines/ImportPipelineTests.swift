import Foundation
import Testing

@testable import Nemoris

/// Ingestion pipeline: format recognition from bytes, reading
/// spreadsheets, CAMT and OFX statements.
///
/// The rule everything else rests on: NEVER infer a format from an
/// extension, and never treat a successful Latin-1 decode as proof that
/// the content is text — any byte sequence is valid Latin-1, to the point
/// that a screenshot became 670,000 characters of binary sent to the
/// model.
@Suite("Pipeline d'import")
struct ImportPipelineEngineTests {

    // These helpers propagate the caller's location: without it,
    // every failure would point here instead of at the actual test.
    private func expect(_ condition: Bool, _ label: String, _ detail: String = "",
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label)\(detail.isEmpty ? "" : " — \(detail)")",
                sourceLocation: sourceLocation)
    }


    // A harness without XCTest — compiles the REAL engine files
    // (see run_import_pipeline_tests.sh).
    //
    // Covers the PURE engines of the unified import pipeline:
    //   • `ImportFormatSniffer`  — format identification from bytes
    //   • `ZIPArchiveReader`     — ZIP reading (STORE + DEFLATE)
    //   • `XLSXReader`           — spreadsheet → common table
    //   • `LedgerXMLReader`      — CAMT.053 and OFX/QFX
    //   • `ImportElement`        — exchange model, aggregation by source
    //
    // ⚠️ The PURITY guard is this harness itself: none of these files may
    // import PDFKit, Vision, FoundationModels, or SwiftUI without breaking it.



    /// Fixtures root. The test data lives in `Tests/Fixtures/`,
    /// shared with the generation scripts (`build_xlsx_fixture.py`) — duplicating
    /// it into the test bundle would let them drift apart.
    let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Engines
        .deletingLastPathComponent()   // NemorisTests
        .deletingLastPathComponent()   // NemorisApp
        .appendingPathComponent("Tests/Fixtures")


    // MARK: - t1 — Sniffing: the format comes from the BYTES, never the extension

    @Test("Identification du format par les octets d'en-tête")
    func t1() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 40))
        // THE production bug: a shared screenshot arrives named `<uuid>.dat`.
        // Without sniffing it fell into "text", and the Latin-1 decode — which
        // never fails — produced hundreds of thousands of characters of
        // binary sent to the model.
        expect(ImportFormatSniffer.detect(data: png, fileExtension: "dat") == .image,
               "PNG nommé .dat reconnu comme image")
        // And the reverse: a misleading extension shouldn't win either.
        expect(ImportFormatSniffer.detect(data: png, fileExtension: "csv") == .image,
               "PNG nommé .csv reste une image")

        let pdf = Data("%PDF-1.7\n%âãÏÓ\n".utf8)
        expect(ImportFormatSniffer.detect(data: pdf) == .pdf, "signature %PDF")

        let csv = Data("date;libelle;montant\n02/07/2026;CARREFOUR;-42,50\n".utf8)
        expect(ImportFormatSniffer.detect(data: csv) == .text, "CSV = texte")

        let camt = Data("<?xml version=\"1.0\"?><Document><BkToCstmrStmt/></Document>".utf8)
        expect(ImportFormatSniffer.detect(data: camt) == .xml, "CAMT reconnu comme XML")

        // OFX 1.x is NOT XML: it starts with an SGML header block.
        let ofx = Data("OFXHEADER:100\nDATA:OFXSGML\n\n<OFX><SIGNONMSGSRSV1>".utf8)
        expect(ImportFormatSniffer.detect(data: ofx) == .xml, "OFX 1.x SGML rangé en XML")
        expect(ImportFormatSniffer.isOFX(ofx), "dialecte OFX distingué de CAMT")

        // A NUL byte is the marker that keeps binary from passing as text.
        let binary = Data([0x00, 0x01, 0x02, 0x03] + Array(repeating: 0x41, count: 100))
        expect(ImportFormatSniffer.looksLikeText(binary) == false, "octet NUL → pas du texte")
        expect(ImportFormatSniffer.detect(data: binary) == .unknown, "binaire inconnu reste inconnu")

        expect(ImportFormatSniffer.detect(data: Data(), fileExtension: "pdf") == .pdf,
               "fichier vide → repli sur l'extension")

        // Any ZIP isn't necessarily a spreadsheet: the signature alone isn't enough.
        let plainZip = Data([0x50, 0x4B, 0x03, 0x04] + Array("photos/img.png".utf8))
        expect(ImportFormatSniffer.detect(data: plainZip) == .unknown,
               "ZIP sans marqueur OOXML n'est pas un classeur")
    }

    // MARK: - t2 — Reading a ZIP

    @Test("Lecture d'archive ZIP (STORE et DEFLATE)")
    func t2() throws {
        let archive = try! Data(contentsOf: fixturesDirectory.appendingPathComponent("statement_fixture.xlsx"))

        expect(ImportFormatSniffer.detect(data: archive, fileExtension: "") == .spreadsheet,
               "classeur reconnu par son contenu OOXML")

        switch ZIPArchiveReader.entries(in: archive) {
        case .failure(let error):
            expect(false, "listing des entrées", error.reason)
        case .success(let entries):
            expect(entries.count == 5, "5 entrées listées", "\(entries.count)")
            expect(entries.contains { $0.name == "xl/sharedStrings.xml" }, "chaînes partagées présentes")
            // The central directory is read at the end of the archive, not the
            // local headers: that's what guarantees real sizes even when
            // the archive was written in streaming mode.
            expect(entries.allSatisfy { $0.uncompressedSize > 0 }, "tailles réelles connues")
        }

        switch ZIPArchiveReader.extract(named: "xl/workbook.xml", from: archive) {
        case .failure(let error):
            expect(false, "décompression DEFLATE", error.reason)
        case .success(let xml):
            let text = String(decoding: xml, as: UTF8.self)
            expect(text.contains("Operations"), "contenu inflaté correct")
            expect(text.hasPrefix("<?xml"), "flux DEFLATE brut décodé sans en-tête zlib")
        }

        switch ZIPArchiveReader.extract(named: "absent.xml", from: archive) {
        case .success: expect(false, "entrée absente → erreur")
        case .failure: expect(true, "entrée absente → erreur")
        }
    }

    // MARK: - t3 — Classeur XLSX

    @Test("Classeur XLSX → table commune")
    func t3() throws {
        let archive = try! Data(contentsOf: fixturesDirectory.appendingPathComponent("statement_fixture.xlsx"))

        switch XLSXReader.grids(from: archive) {
        case .failure(let error):
            expect(false, "lecture du classeur", error.reason)
        case .success(let grids):
            expect(grids.count == 2, "2 feuilles lues", "\(grids.count)")
            guard let sheet = grids.first else { break }

            expect(sheet.sheetName == "Operations", "nom d'onglet repris", sheet.sheetName ?? "nil")
            // The identity block at the top ("BANK STATEMENT", IBAN) must not
            // be mistaken for the header: the table would end up with a single column.
            expect(sheet.hasExplicitHeader, "vraie ligne d'en-tête trouvée sous le bloc d'identité")
            expect(sheet.headers == ["Date", "Libelle", "Montant", "Devise"],
                   "en-têtes lus depuis les chaînes partagées", "\(sheet.headers)")
            expect(sheet.rows.count == 3, "3 lignes de données", "\(sheet.rows.count)")
            expect(sheet.isTabular, "table exploitable par l'écran de mapping")

            if sheet.rows.count == 3 {
                // Excel stores dates as a serial number; without conversion the
                // column comes out as "45845" and no format recognizes it.
                expect(sheet.rows[0][0] == "2025-07-02",
                       "série Excel convertie en date", sheet.rows[0][0])
                // A shared string cut by a formatting run must be
                // stitched back together, otherwise the label is truncated at the 1st style change.
                expect(sheet.rows[0][1] == "CARREFOUR MARKET PARIS",
                       "runs `<r><t>` concaténés", sheet.rows[0][1])
                expect(sheet.rows[0][2] == "-42.5", "montant brut conservé", sheet.rows[0][2])
                expect(sheet.rows[0][3] == "EUR", "chaîne inline lue", sheet.rows[0][3])

                // ⚠️ THE spreadsheet trap: an empty cell is NOT written in
                // the XML. Without reading the `r` reference, everything shifts left — here
                // "EUR" would move up into the Amount column for the rest of the file.
                expect(sheet.rows[2].count >= 4, "ligne à trou conservée à 4 colonnes",
                       "\(sheet.rows[2].count)")
                expect(sheet.rows[2][1] == "PRLV EDF", "libellé en place", sheet.rows[2][1])
                expect(sheet.rows[2][2] == "", "cellule absente rendue vide, pas décalée",
                       sheet.rows[2][2])
                expect(sheet.rows[2][3] == "EUR", "colonne suivante NON décalée", sheet.rows[2][3])
            }
        }

        // Sheet sorting: lexicographically, sheet10 would come before sheet2.
        expect(XLSXReader.sheetIndex("xl/worksheets/sheet2.xml")
               < XLSXReader.sheetIndex("xl/worksheets/sheet10.xml"),
               "feuilles triées numériquement, pas lexicographiquement")

        // OOXML column references.
        expect(XLSXCellReference.columnIndex(from: "A1") == 0, "A → 0")
        expect(XLSXCellReference.columnIndex(from: "D7") == 3, "D → 3")
        expect(XLSXCellReference.columnIndex(from: "AA1") == 26, "AA → 26")
        expect(XLSXCellReference.columnIndex(from: "BC12") == 54, "BC → 54")

        // The 25,569-day offset accounts for Excel's fictitious February 29, 1900.
        let date = XLSXCellReference.date(fromSerial: 45840)
        expect(date.map { XLSXCellReference.isoFormatter.string(from: $0) } == "2025-07-02",
               "époque Excel (bissextile 1900 comprise)")
        // The constant's anchor point: serial 25569 IS January 1st, 1970.
        expect(XLSXCellReference.date(fromSerial: 25569)
                .map { XLSXCellReference.isoFormatter.string(from: $0) } == "1970-01-01",
               "série 25569 = époque Unix")
        expect(XLSXCellReference.date(fromSerial: 0) == nil, "série invalide rejetée")
    }

    // MARK: - t4 — CAMT.053

    @Test("Relevé CAMT.053 (ISO 20022)")
    func t4() throws {
        // A DELIBERATE namespace prefix (`ns2:`): real producers use
        // them, and comparing the full qualified name would make parsing fail
        // on half of real-world files.
        let camt = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ns2:Document xmlns:ns2="urn:iso:std:iso:20022:tech:xsd:camt.053.001.02">
          <ns2:BkToCstmrStmt>
            <ns2:Stmt>
              <ns2:Id>STMT-2026-07</ns2:Id>
              <ns2:Ntry>
                <ns2:Amt Ccy="EUR">42.50</ns2:Amt>
                <ns2:CdtDbtInd>DBIT</ns2:CdtDbtInd>
                <ns2:BookgDt><ns2:Dt>2026-07-02</ns2:Dt></ns2:BookgDt>
                <ns2:ValDt><ns2:Dt>2026-07-03</ns2:Dt></ns2:ValDt>
                <ns2:NtryDtls><ns2:TxDtls>
                  <ns2:Amt Ccy="EUR">45.00</ns2:Amt>
                  <ns2:RltdPties><ns2:Cdtr><ns2:Nm>CARREFOUR MARKET</ns2:Nm></ns2:Cdtr></ns2:RltdPties>
                  <ns2:RmtInf><ns2:Ustrd>ACHAT CB 01/07</ns2:Ustrd></ns2:RmtInf>
                </ns2:TxDtls></ns2:NtryDtls>
              </ns2:Ntry>
              <ns2:Ntry>
                <ns2:Amt Ccy="EUR">2350.00</ns2:Amt>
                <ns2:CdtDbtInd>CRDT</ns2:CdtDbtInd>
                <ns2:BookgDt><ns2:Dt>2026-07-03</ns2:Dt></ns2:BookgDt>
                <ns2:AddtlNtryInf>VIR SEPA SALAIRE ACME</ns2:AddtlNtryInf>
              </ns2:Ntry>
            </ns2:Stmt>
          </ns2:BkToCstmrStmt>
        </ns2:Document>
        """
        expect(LedgerXMLReader.detectDialect(camt) == .camt053, "dialecte CAMT reconnu")

        switch LedgerXMLReader.parse(text: camt) {
        case .failure(let error):
            expect(false, "parsing CAMT", error.reason)
        case .success(let payloads):
            expect(payloads.count == 2, "2 écritures", "\(payloads.count)")
            guard payloads.count == 2,
                  case .transaction(let debit) = payloads[0],
                  case .transaction(let credit) = payloads[1] else {
                expect(false, "payloads de type transaction"); break
            }

            expect(debit.date == "2026-07-02", "date COMPTABLE préférée à la date de valeur", debit.date)
            // ⚠️ CAMT ALWAYS writes a positive amount: the sign comes from
            // `CdtDbtInd`. Reading the number alone would book a debit as income.
            expect(debit.amount == -42.50, "DBIT → montant négatif", "\(debit.amount)")
            // The detail's `<Amt>` of 45.00 (amount before fees) must NOT
            // overwrite the entry's own amount.
            expect(abs(debit.amount) == 42.50, "montant de l'écriture, pas celui des détails")
            expect(debit.label == "ACHAT CB 01/07", "libellé depuis RmtInf/Ustrd", debit.label)
            expect(debit.isSignExplicit, "signe déclaré par le format, pas déduit")
            expect(debit.confidence == 1.0, "confiance maximale sur un format nommé")

            expect(credit.amount == 2350.0, "CRDT → montant positif", "\(credit.amount)")
            expect(credit.label == "VIR SEPA SALAIRE ACME",
                   "repli sur AddtlNtryInf quand RmtInf est absent", credit.label)
        }

        // An entry with neither a date nor an amount must produce NO row:
        // the engine never invents one.
        let empty = """
        <Document><BkToCstmrStmt><Stmt><Ntry><CdtDbtInd>DBIT</CdtDbtInd></Ntry></Stmt></BkToCstmrStmt></Document>
        """
        if case .success(let payloads) = LedgerXMLReader.parse(text: empty) {
            expect(payloads.isEmpty, "écriture incomplète ignorée", "\(payloads.count)")
        } else {
            expect(false, "écriture incomplète ignorée")
        }
    }

    // MARK: - t5 — OFX / QFX

    @Test("Relevé OFX (SGML 1.x et XML 2.0)")
    func t5() throws {
        // OFX 1.x: UNCLOSED tags. `XMLParser` rejects this document outright,
        // hence the tolerant tokenizer — and it's the most widespread dialect.
        let ofx = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102

        <OFX>
        <BANKMSGSRSV1><STMTTRNRS><STMTRS>
        <BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>POS
        <DTPOSTED>20260702120000.000[-5:EST]
        <TRNAMT>-42.50
        <FITID>2026070201
        <NAME>CARREFOUR MARKET
        <MEMO>ACHAT CB 01/07
        </STMTTRN>
        <STMTTRN>
        <TRNTYPE>DIRECTDEP
        <DTPOSTED>20260703
        <TRNAMT>2350.00
        <FITID>2026070301
        <NAME>ACME SA
        <MEMO>SALAIRE JUILLET
        </STMTTRN>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260705
        <TRNAMT>18.90
        <FITID>2026070501
        <NAME>REMBOURSEMENT MUTUELLE
        </STMTTRN>
        </BANKTRANLIST>
        </STMTRS></STMTTRNRS></BANKMSGSRSV1>
        </OFX>
        """
        expect(LedgerXMLReader.detectDialect(ofx) == .ofx, "dialecte OFX reconnu")

        switch LedgerXMLReader.parse(text: ofx) {
        case .failure(let error):
            expect(false, "parsing OFX SGML", error.reason)
        case .success(let payloads):
            expect(payloads.count == 3, "3 opérations", "\(payloads.count)")
            guard payloads.count == 3,
                  case .transaction(let first) = payloads[0],
                  case .transaction(let second) = payloads[1],
                  case .transaction(let third) = payloads[2] else {
                expect(false, "payloads de type transaction"); break
            }

            expect(first.date == "2026-07-02", "horodatage OFX réduit au jour", first.date)
            // ⚠️ In OFX, unlike CAMT, the sign is IN the number.
            expect(first.amount == -42.50, "signe porté par le nombre", "\(first.amount)")
            expect(first.label == "CARREFOUR MARKET — ACHAT CB 01/07",
                   "NAME et MEMO combinés", first.label)
            expect(first.paymentTypeHint == "CB", "POS → CB", first.paymentTypeHint ?? "nil")

            expect(second.amount == 2350.0, "crédit positif", "\(second.amount)")
            expect(second.paymentTypeHint == "VIREMENT", "DIRECTDEP → VIREMENT",
                   second.paymentTypeHint ?? "nil")

            // ⚠️ A refund is a `DEBIT` with a POSITIVE amount. Forcing the
            // sign from TRNTYPE would flip it — hence the "the number is
            // authoritative" rule in OFX.
            expect(third.amount == 18.90, "DEBIT positif conservé positif", "\(third.amount)")
            expect(third.label == "REMBOURSEMENT MUTUELLE", "MEMO absent → NAME seul", third.label)
        }

        // OFX 2.0: the same content, in well-formed XML. The same tokenizer must
        // absorb it with no dedicated branch.
        let ofx2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?OFX OFXHEADER="200" VERSION="211"?>
        <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
          <STMTTRN>
            <TRNTYPE>CHECK</TRNTYPE>
            <DTPOSTED>20260710</DTPOSTED>
            <TRNAMT>-120.00</TRNAMT>
            <NAME>CHEQUE 4412</NAME>
          </STMTTRN>
        </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        if case .success(let payloads) = LedgerXMLReader.parse(text: ofx2),
           payloads.count == 1, case .transaction(let tx) = payloads[0] {
            expect(tx.amount == -120.0, "OFX 2.0 XML lu par le même tokenizer", "\(tx.amount)")
            expect(tx.label == "CHEQUE 4412", "libellé OFX 2.0", tx.label)
            expect(tx.paymentTypeHint == "CHEQUE", "CHECK → CHEQUE", tx.paymentTypeHint ?? "nil")
        } else {
            expect(false, "OFX 2.0 XML lu par le même tokenizer")
        }

        // A broker's OFX: stock trades come out as an investment
        // payload, without going through ISIN anchoring or the AI.
        let invest = """
        OFXHEADER:100
        <OFX><INVSTMTMSGSRSV1><INVSTMTTRNRS><INVSTMTRS><INVTRANLIST>
        <BUYSTOCK>
        <INVBUY>
        <INVTRAN><DTTRADE>20260415</DTTRADE></INVTRAN>
        <SECID><UNIQUEID>LU1681043599<UNIQUEIDTYPE>ISIN</SECID>
        <UNITS>2.0
        <UNITPRICE>485.30
        <COMMISSION>1.99
        <TOTAL>-972.59
        </INVBUY>
        </BUYSTOCK>
        <INCOME>
        <INVTRAN><DTTRADE>20260702</DTTRADE></INVTRAN>
        <SECID><UNIQUEID>FR0000120271<UNIQUEIDTYPE>ISIN</SECID>
        <TOTAL>34.53
        <MEMO>DIVIDENDE TOTALENERGIES
        </INCOME>
        </INVTRANLIST></INVSTMTRS></INVSTMTTRNRS></INVSTMTMSGSRSV1></OFX>
        """
        if case .success(let payloads) = LedgerXMLReader.parse(text: invest) {
            let orders = payloads.compactMap { payload -> ExtractedStatementOrder? in
                if case .investmentOrder(let order) = payload { return order }
                return nil
            }
            expect(orders.count == 2, "2 ordres depuis un OFX de courtier", "\(orders.count)")
            if orders.count == 2 {
                expect(orders[0].orderType == "BUY", "BUYSTOCK → BUY", orders[0].orderType)
                expect(orders[0].isin == "LU1681043599", "ISIN lu depuis SECID", orders[0].isin)
                expect(orders[0].quantity == 2.0, "quantité", "\(orders[0].quantity)")
                expect(orders[0].unitPrice == 485.30, "cours unitaire", "\(orders[0].unitPrice)")
                expect(orders[0].fees == 1.99, "commission", "\(orders[0].fees)")
                expect(orders[0].executedAt == "2026-04-15", "date d'exécution", orders[0].executedAt)
                // ⚠️ A dividend has NEITHER a quantity NOR a price: requiring `UNITS > 0`
                // as for the others would make every income
                // row disappear, since they only carry a total.
                expect(orders[1].orderType == "DIV", "INCOME → DIV", orders[1].orderType)
                expect(orders[1].unitPrice == 34.53, "dividende valorisé par son total",
                       "\(orders[1].unitPrice)")
            }
        } else {
            expect(false, "2 ordres depuis un OFX de courtier")
        }

        // An XML that's neither CAMT nor OFX must be rejected CLEANLY, never
        // interpreted at random.
        switch LedgerXMLReader.parse(text: "<?xml version=\"1.0\"?><catalog><item/></catalog>") {
        case .success: expect(false, "XML étranger refusé")
        case .failure: expect(true, "XML étranger refusé")
        }
    }

    // MARK: - t6 — Exchange model

    @Test("ImportElement : agrégation par source et inspection")
    func t6() throws {
        func origin(_ name: String, _ index: Int, _ unit: Int) -> ImportElementOrigin {
            ImportElementOrigin(sourceName: name, sourceIndex: index,
                                unitNumber: unit, unitIndexInSource: 1, kind: .pdf)
        }
        let tx = ExtractedBankTransaction(date: "2026-07-02", amount: -42.5,
                                          label: "CARREFOUR", paymentTypeHint: "CB",
                                          isSignExplicit: true, confidence: 0.9)

        let result = ImportBatchResult(
            elements: [
                ImportElement(origin: origin("releve.pdf", 0, 1), payload: .transaction(tx)),
                ImportElement(origin: origin("releve.pdf", 0, 2), payload: .transaction(tx)),
                ImportElement(origin: origin("capture.png", 1, 3), payload: .transaction(tx)),
            ],
            units: [
                ImportUnitReport(origin: origin("releve.pdf", 0, 1), recognizedCount: 2),
                ImportUnitReport(origin: origin("releve.pdf", 0, 2), recognizedCount: 0,
                                 diagnostic: .nothingRecognized),
                ImportUnitReport(origin: origin("capture.png", 1, 3), recognizedCount: 1),
                // A source that produced NOTHING: that's exactly the one that
                // needs to show up in the per-source detail, and that an aggregated total hides.
                ImportUnitReport(origin: origin("vide.csv", 2, 4), recognizedCount: 0,
                                 diagnostic: .noTextExtracted),
            ])

        let sources = result.perSource()
        expect(sources.count == 3, "3 sources distinctes", "\(sources.count)")
        expect(sources.map(\.sourceName) == ["releve.pdf", "capture.png", "vide.csv"],
               "ordre du batch conservé", "\(sources.map(\.sourceName))")
        expect(sources[0].elementCount == 2, "2 éléments pour le PDF", "\(sources[0].elementCount)")
        expect(sources[0].unitCount == 2, "2 unités pour le PDF", "\(sources[0].unitCount)")
        expect(sources[0].failedUnitCount == 1, "1 unité en échec repérée",
               "\(sources[0].failedUnitCount)")
        expect(sources[2].isEmptyResult, "source muette signalée comme telle")
        expect(sources[2].summaryLabel(noun: "opération") == "aucune opération",
               "libellé du cas vide", sources[2].summaryLabel(noun: "opération"))
        expect(sources[0].summaryLabel(noun: "opération") == "2 opérations",
               "libellé au pluriel", sources[0].summaryLabel(noun: "opération"))

        // Debug inspection: on the NORMALIZED structure, not on OCR text —
        // it's the only format that also covers CSV, spreadsheets, and XML.
        let json = result.debugJSON(sourceIndex: 0)
        expect(json.contains("CARREFOUR"), "JSON de debug produit")
        expect(json.contains("releve.pdf"), "origine tracée dans le JSON")
        expect(!json.contains("capture.png"), "filtre par source respecté")

        // The confidence value comes up from the payload without needing to unwrap it.
        expect(result.elements[0].confidence == 0.9, "confiance reprise du payload",
               "\(result.elements[0].confidence)")
        expect(result.elements[0].kind == .transaction, "type d'élément exposé")
    }

    // MARK: - t7 — Fusion de deux passes

    @Test("Fusion de deux passes (CSV mappés, puis documents analysés)")
    func t7() throws {
        func batch(_ name: String) -> ImportBatchResult {
            let origin = ImportElementOrigin(sourceName: name, sourceIndex: 0,
                                             unitNumber: 1, unitIndexInSource: 1, kind: .text)
            let tx = ExtractedBankTransaction(date: "2026-07-02", amount: -10,
                                              label: name, paymentTypeHint: nil,
                                              isSignExplicit: true, confidence: 1)
            return ImportBatchResult(
                elements: [ImportElement(origin: origin, payload: .transaction(tx))],
                units: [ImportUnitReport(origin: origin, recognizedCount: 1)])
        }

        let merged = ImportBatchResult.merge(batch("a.csv"), batch("b.pdf"))
        expect(merged.elements.count == 2, "éléments cumulés", "\(merged.elements.count)")
        // ⚠️ Without renumbering, the two passes both restart at sourceIndex 0 and
        // unitNumber 1: aggregation by source would merge them into ONE
        // source, and a failure report would point to an ambiguous unit.
        expect(merged.perSource().count == 2, "sources restées distinctes",
               "\(merged.perSource().count)")
        expect(merged.units.map(\.origin.unitNumber) == [1, 2], "unités renumérotées à la suite",
               "\(merged.units.map(\.origin.unitNumber))")
        expect(merged.elements.map(\.origin.sourceIndex) == [0, 1], "sources renumérotées",
               "\(merged.elements.map(\.origin.sourceIndex))")
    }

    // MARK: - t8 — Table commune CSV / classeur

    @Test("CSV et classeur produisent la MÊME table")
    func t8() throws {
        let csv = """
        Date;Libelle;Montant
        02/07/2026;CARREFOUR MARKET;-42,50
        03/07/2026;VIR SEPA SALAIRE;2350,00
        """
        guard let grid = CSVParser.parse(content: csv) else {
            expect(false, "CSV parsé"); return
        }
        expect(grid.headers == ["Date", "Libelle", "Montant"], "en-têtes CSV", "\(grid.headers)")
        expect(grid.rows.count == 2, "2 lignes", "\(grid.rows.count)")
        expect(grid.isTabular, "table exploitable")
        expect(grid.separator == ";", "séparateur détecté", grid.separator)

        // A source with a SINGLE column isn't a table: sending it to mapping
        // would ask the user to designate columns that don't exist.
        let prose = "RELEVE DE COMPTE\nLe 2 juillet, achat CARREFOUR de 42,50 EUR\n"
        let proseGrid = CSVParser.parse(content: prose)
        expect(proseGrid?.isTabular != true, "texte en prose non traité comme une table")

        // A separator forced by the user: autodetection gets it wrong on
        // files whose labels contain commas.
        let ambiguous = "Date,Libelle,Montant\n02/07/2026,\"CARREFOUR, PARIS\",-42.50"
        let forced = CSVParser.parse(content: ambiguous, forcedSeparator: ",")
        expect(forced?.rows.first?.count == 3, "guillemets respectés avec séparateur imposé",
               "\(forced?.rows.first?.count ?? -1)")
        expect(forced?.rows.first?[1] == "CARREFOUR, PARIS", "virgule protégée par les guillemets",
               forced?.rows.first?[1] ?? "nil")

        // ESCAPED quotes (`""` inside a field). Investment import had
        // its own splitting logic, which toggled `inQuotes` on every quote
        // and so broke on this case — it now goes through this parser.
        let escaped = CSVParser.parse(content: "libelle;montant\n\"dit \"\"bonjour\"\"\";2")
        expect(escaped?.rows.first?[0] == "dit \"bonjour\"", "guillemet échappé préservé",
               escaped?.rows.first?[0] ?? "nil")

        // Amounts: the traps that made valid rows get rejected.
        expect(CSVParser.parseAmount("1 234,56", decimal: ",") == 1234.56,
               "séparateur de milliers (espace)")
        expect(CSVParser.parseAmount("1\u{00A0}234,56", decimal: ",") == 1234.56,
               "espace INSÉCABLE des milliers")
        expect(CSVParser.parseAmount("1,234.56", decimal: ".") == 1234.56,
               "convention anglo-saxonne")
        expect(CSVParser.parseAmount("(42,50)", decimal: ",") == -42.50,
               "négatif comptable entre parenthèses")
    }

    // MARK: - t9 — Session payload discriminated by destination

    @Test("Session : le contenu de rows_json dépend de la destination")
    func t9() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Transactions: [ImportSessionRow], which carries the RESOLUTION state.
        var row = ImportSessionRow(sourceRowNumber: 1, rawLabel: "CARREFOUR",
                                   date: Date(timeIntervalSince1970: 1_770_000_000),
                                   amount: -42.5, sourceFile: "releve.csv")
        row.userAction = .confirmed
        row.assignedPayeeId = 7

        let rowsJSON = try! encoder.encode([row])
        let decodedRows = try! decoder.decode([ImportSessionRow].self, from: rowsJSON)
        expect(decodedRows.count == 1, "aller-retour des lignes de session")
        expect(decodedRows[0].userAction == .confirmed, "action utilisateur conservée")
        expect(decodedRows[0].assignedPayeeId == 7, "tier assigné conservé")
        expect(decodedRows[0].sourceFile == "releve.csv", "origine conservée")

        // ⚠️ Pending-row counting is done by STRING SCAN, not by
        // decoding (cost on a large session). If the enum's representation
        // changes, this scan silently becomes wrong — hence this check
        // against the exact expected literal.
        var pending = ImportSessionRow(sourceRowNumber: 2, rawLabel: "EDF",
                                       date: Date(), amount: -89.9)
        pending.userAction = .pending
        let pendingJSON = String(decoding: try! encoder.encode([pending]), as: UTF8.self)
        expect(pendingJSON.contains("\"userAction\":\"pending\""),
               "littéral scanné par countPending inchangé")

        // Investments: ImportBatchResult, with no resolution state.
        let order = ExtractedStatementOrder(
            orderType: "BUY", assetName: "Epargne MSCI World", isin: "LU1681043599",
            ticker: "CW8", quantity: 2, unitPrice: 485.30, fees: 1.99,
            executedAt: "2026-04-15", currency: "EUR", notes: nil, confidence: 0.9)
        let batch = ImportBatchResult(
            elements: [ImportElement(
                origin: ImportElementOrigin(sourceName: "avis.pdf", kind: .pdf),
                payload: .investmentOrder(order))],
            units: [ImportUnitReport(
                origin: ImportElementOrigin(sourceName: "avis.pdf", kind: .pdf),
                recognizedCount: 1)])

        let batchJSON = try! encoder.encode(batch)
        let decodedBatch = try! decoder.decode(ImportBatchResult.self, from: batchJSON)
        expect(decodedBatch.elements.count == 1, "aller-retour du lot d'import")
        if case .investmentOrder(let restored) = decodedBatch.elements[0].payload {
            expect(restored == order, "ordre restitué à l'identique")
        } else {
            expect(false, "ordre restitué à l'identique")
        }
        expect(decodedBatch.units.first?.origin.sourceName == "avis.pdf",
               "origine des unités conservée")

        // The two forms are NOT interchangeable: it's really the `destination`
        // column that decides, never a decoding attempt.
        expect((try? decoder.decode([ImportSessionRow].self, from: batchJSON)) == nil,
               "un lot ne se décode pas comme des lignes")
        expect((try? decoder.decode(ImportBatchResult.self, from: rowsJSON)) == nil,
               "des lignes ne se décodent pas comme un lot")
    }

    // MARK: - t10 — Encoding: the BOM overrides any heuristic

    @Test("Décodage texte, UTF-16 compris")
    func t10() throws {
        let csv = "date;libelle;montant\n02/07/2026;CARREFOUR;-42,50"

        func utf16Data(bigEndian: Bool, bom: Bool) -> Data {
            var data = Data()
            if bom { data.append(contentsOf: bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) }
            for unit in csv.utf16 {
                let high = UInt8(unit >> 8), low = UInt8(unit & 0xFF)
                data.append(contentsOf: bigEndian ? [high, low] : [low, high])
            }
            return data
        }

        // ⚠️ THE regression: a UTF-16 big-endian CSV decoded as little-endian
        // produces CJK ideograms ("date" → 搀愀琀攀). The file became
        // unreadable, so no longer tabular, so sent to the AI instead of the
        // deterministic parser — hence both the Chinese characters and the slowdown on a CSV.
        let beWithBOM = utf16Data(bigEndian: true, bom: true)
        expect(ImportFormatSniffer.decodeText(beWithBOM)?.contains("CARREFOUR") == true,
               "UTF-16 BE avec BOM décodé correctement",
               ImportFormatSniffer.decodeText(beWithBOM).map { String($0.prefix(20)) } ?? "nil")
        expect(ImportFormatSniffer.decodeText(beWithBOM)?.contains("\u{6400}") == false,
               "aucun idéogramme parasite")

        let leWithBOM = utf16Data(bigEndian: false, bom: true)
        expect(ImportFormatSniffer.decodeText(leWithBOM)?.contains("CARREFOUR") == true,
               "UTF-16 LE avec BOM décodé correctement")

        // Without a BOM: the position of the null bytes gives the endianness.
        expect(ImportFormatSniffer.decodeText(utf16Data(bigEndian: true, bom: false))?
                .contains("CARREFOUR") == true, "UTF-16 BE sans BOM deviné")
        expect(ImportFormatSniffer.decodeText(utf16Data(bigEndian: false, bom: false))?
                .contains("CARREFOUR") == true, "UTF-16 LE sans BOM deviné")

        // A UTF-16 BOM is an explicit declaration: it's text, despite the
        // null bytes that would fail the generic test.
        expect(ImportFormatSniffer.looksLikeText(beWithBOM), "BOM UTF-16 reconnu comme texte")
        expect(ImportFormatSniffer.detect(data: beWithBOM) == .text, "UTF-16 sans extension → texte")

        // And the CSV becomes TABULAR again, so it no longer goes to the AI.
        if let text = ImportFormatSniffer.decodeText(beWithBOM),
           let grid = CSVParser.parse(content: text) {
            expect(grid.isTabular, "CSV UTF-16 exploitable par le mapping (donc pas d'IA)")
            expect(grid.headers.count == 3, "3 colonnes", "\(grid.headers.count)")
        } else {
            expect(false, "CSV UTF-16 exploitable par le mapping (donc pas d'IA)")
        }

        // Non-regression: plain UTF-8 isn't mistaken for UTF-16.
        expect(ImportFormatSniffer.decodeText(Data(csv.utf8))?.contains("CARREFOUR") == true,
               "UTF-8 sans BOM inchangé")
        let utf8BOM = Data([0xEF, 0xBB, 0xBF] + Array(csv.utf8))
        expect(ImportFormatSniffer.decodeText(utf8BOM)?.hasPrefix("date") == true,
               "BOM UTF-8 retiré")
    }

    // MARK: - t11 — Model JSON: formatting repair

    @Test("Réparation d'un JSON coupé par la mise en forme")
    func t11() throws {
        // ⚠️ A REAL case: the model split a key's name across two lines. That's
        // invalid JSON (a raw control character inside a string), `JSONDecoder`
        // throws, and the ENTIRE document is lost — eight correctly
        // extracted operations resulted in "no transaction to import".
        let broken = """
        {
          "transactions": [
            {
              "date": "2026-07-22",
              "label": "Carrefour City",
              "amount": -3.98,
              "payment_
                type": "CB"
            }
          ]
        }
        """
        let repaired = LenientJSON.extractObject(from: broken)
        expect(repaired.contains("\"payment_type\""), "clé recollée sans espace parasite",
               repaired.contains("payment_ type") ? "espace inséré" : String(repaired.prefix(80)))

        guard let data = repaired.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["transactions"] as? [[String: Any]] else {
            expect(false, "JSON réparé décodable"); return
        }
        expect(rows.count == 1, "1 opération récupérée", "\(rows.count)")
        expect(rows.first?["payment_type"] as? String == "CB", "valeur de la clé recollée")

        // A split VALUE is rejoined with a space: it's a label whose
        // words got separated, not an identifier.
        let wrappedValue = """
        {"transactions":[{"label":"CARREFOUR
            CITY PARIS","amount":-1.0,"date":"2026-07-22"}]}
        """
        let fixedValue = LenientJSON.repaired(wrappedValue)
        expect(fixedValue.contains("CARREFOUR CITY PARIS"),
               "libellé recollé avec une espace",
               fixedValue.contains("CARREFOURCITY") ? "mots collés" : String(fixedValue.prefix(60)))

        // Non-regression: valid JSON passes through unchanged, escapes included.
        let valid = #"{"label":"dit \"bonjour\"","n":1}"#
        expect(LenientJSON.repaired(valid) == valid, "JSON valide inchangé",
               LenientJSON.repaired(valid))

        // Markdown code fences that models add are stripped.
        let fenced = "```json\n" + #"{"a":1}"# + "\n```"
        expect(LenientJSON.extractObject(from: fenced) == #"{"a":1}"#,
               "balises de code retirées", LenientJSON.extractObject(from: fenced))

        // ⚠️ We close NOTHING: a truncated structure must remain a visible
        // error, not a guessed value.
        let truncated = #"{"transactions":[{"label":"X""#
        expect((try? JSONSerialization.jsonObject(
                    with: Data(LenientJSON.repaired(truncated).utf8))) == nil,
               "JSON tronqué reste invalide (rien n'est inventé)")
    }

    // MARK: - t12 — A syntax mistake only costs ONE line

    @Test("Décodage objet par objet d'une réponse fautive")
    func t12() throws {
        // ⚠️ REAL JSON returned by a model on a banking app screenshot.
        // Two punctuation mistakes: a trailing comma (3rd object) and a
        // missing opening key quote preceded by a stray comma (8th). Decoding
        // the WHOLE document failed, so all eight operations
        // were lost — six of them perfectly well-formed.
        let response = """
        {
          "transactions": [
            { "date": "2026-07-22", "label": "Carrefour City", "amount": -3.98, "payment_type": "CB" },
            { "date": "2026-07-22", "label": "Amschc", "amount": -6.00, "payment_type": "CB" },
            {
              "date": "2026-07-21",
              "label": "Carrefour City",
              "amount": -6.98,
            },
            { "date": "2026-07-21", "label": "Carrefour City", "amount": -4.61, "payment_type": "CB" },
            { "date": "2026-07-21", "label": "Image Numere", "amount": -28.56, "payment_type": "CB" },
            { "date": "2026-07-20", "label": "Carrefour City", "amount": -10.62, "payment_type": "CB" },
            { "date": "2026-07-20", "label": "Terrys Cafe", "amount": -68.80, "payment_type": "CB" },
            {
              "date": "2026-07-18",
              "label": "Lmw.Billetweb",
              , amount": -6.00,
              "payment_type": "CB"
            }
          ]
        }
        """

        // The whole document is still invalid — we don't claim otherwise.
        expect((try? JSONSerialization.jsonObject(with: Data(response.utf8))) == nil,
               "le document brut est bien invalide (précondition)")

        let objects = LenientJSON.innermostObjects(in: response)
        expect(objects.count == 8, "8 objets isolés malgré les fautes", "\(objects.count)")

        let decoded = objects.compactMap { object -> [String: Any]? in
            guard let data = object.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        // BOTH mistakes are repairable punctuation: everything is recovered.
        expect(decoded.count == 8, "8 opérations décodées", "\(decoded.count)")
        expect(decoded.compactMap { $0["label"] as? String }.contains("Terrys Cafe"),
               "libellé conservé")
        expect(decoded.compactMap { $0["amount"] as? Double }.contains(-6.98),
               "l'objet à virgule finale est récupéré")
        expect(decoded.compactMap { $0["amount"] as? Double }.contains(-6.00),
               "l'objet à guillemet manquant est récupéré")

        // Repairs taken one at a time.
        expect(LenientJSON.repairSyntax(#"{"a":1,}"#) == #"{"a":1}"#,
               "virgule finale retirée", LenientJSON.repairSyntax(#"{"a":1,}"#))
        expect(LenientJSON.repairSyntax(#"{"a":1,, "b":2}"#).contains(#""b":2"#),
               "virgule dupliquée absorbée")
        expect(LenientJSON.repairSyntax(#"{"a":1, b": 2}"#).contains(#""b": 2"#),
               "guillemet ouvrant de clé restauré", LenientJSON.repairSyntax(#"{"a":1, b": 2}"#))

        // ⚠️ Non-regression: a STRING's content must not be touched by
        // the punctuation repairs.
        let withComma = #"{"label":"CARREFOUR, PARIS","amount":-1}"#
        expect(LenientJSON.repairSyntax(withComma) == withComma,
               "virgule dans un libellé préservée", LenientJSON.repairSyntax(withComma))

        // An unrecoverable object only loses ITSELF.
        let partlyBroken = #"[{"date":"2026-07-01","label":"OK","amount":-1},{"date":BROKEN}]"#
        let salvaged = LenientJSON.innermostObjects(in: partlyBroken).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        expect(salvaged.count == 1, "l'objet valide survit à son voisin cassé", "\(salvaged.count)")
        expect(salvaged.first?["label"] as? String == "OK", "et c'est le bon")
    }

    // MARK: - t13 — FR comma as a decimal separator inside a number

    @Test("Virgule décimale FR dans un nombre JSON")
    func t13() throws {
        expect(LenientJSON.repairSyntax(#"{"amount":-19,50}"#) == #"{"amount":-19.50}"#,
               "négatif corrigé", LenientJSON.repairSyntax(#"{"amount":-19,50}"#))
        expect(LenientJSON.repairSyntax(#"{"amount":19,50}"#) == #"{"amount":19.50}"#,
               "positif corrigé", LenientJSON.repairSyntax(#"{"amount":19,50}"#))
        // The real next field separator stays intact: the comma that
        // introduces "payment_type" has no digit right after it, so the pattern
        // never touches it.
        let field = #"{"amount":-19,50,"payment_type":null}"#
        expect(LenientJSON.repairSyntax(field) == #"{"amount":-19.50,"payment_type":null}"#,
               "séparateur de champ suivant intact", LenientJSON.repairSyntax(field))
        // An integer followed by a field that STARTS with a digit isn't a
        // false decimal (e.g. two consecutive numeric fields): anchored
        // right after ":", never after another value.
        expect(LenientJSON.repairSyntax(#"{"quantity":4,"amount":-19,50}"#)
                   == #"{"quantity":4,"amount":-19.50}"#,
               "un entier voisin n'est pas confondu avec une décimale")

        // A replica of the real-world case: 9 operations, FR decimals on 4 of
        // them, none lost once repaired.
        let real = #"""
        [
          {"date":"2026-07-31","label":"Carrefour City","amount":-19,50,"payment_type":null},
          {"date":"2026-07-31","label":"Sunday Melt Camb","amount":-17,49,"payment_type":"Divers"},
          {"date":"2026-07-31","label":"Sumup Midnight","amount":-13,00,"payment_type":"Divers"},
          {"date":"2026-07-31","label":"Wanderlust","amount":-9,00,"payment_type":"Divers"},
          {"date":"2026-07-31","label":"Carrefour City","amount":-14,08,"payment_type":null},
          {"date":"2026-07-29","label":"Uber Eats Pe","amount":-20,03,"payment_type":"CB"},
          {"date":"2026-07-29","label":"Soundcloud","amount":-5,99,"payment_type":"VIREMENT"},
          {"date":"2026-07-29","label":"Carrefour City","amount":-9,38,"payment_type":null},
          {"date":"2026-07-29","label":"Dac Carrefour Ma","amount":-20,01,"payment_type":"PRELEVEMENT"}
        ]
        """#
        let recovered = LenientJSON.innermostObjects(in: real).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        expect(recovered.count == 9, "les 9 opérations sont récupérées", "\(recovered.count)")
        let amounts = recovered.compactMap { $0["amount"] as? Double }
        expect(amounts.count == 9, "les 9 montants décodent en Double", "\(amounts.count)")
        expect(amounts.contains(-19.50), "premier montant correct")
        expect(amounts.contains(-20.01), "dernier montant correct")
    }
}
