import Foundation

// Harness sans XCTest — compile les fichiers RÉELS des moteurs
// (cf. run_import_pipeline_tests.sh).
//
// Couvre les moteurs PURS du pipeline d'import unifié :
//   • `ImportFormatSniffer`  — identification du format par les octets
//   • `ZIPArchiveReader`     — lecture ZIP (STORE + DEFLATE)
//   • `XLSXReader`           — classeur → table commune
//   • `LedgerXMLReader`      — CAMT.053 et OFX/QFX
//   • `ImportElement`        — modèle d'échange, agrégation par source
//
// ⚠️ Le garde-fou de PURETÉ est ce harnais lui-même : aucun de ces fichiers ne
// peut importer PDFKit, Vision, FoundationModels ni SwiftUI sans le casser.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

/// Racine des fixtures, relative à ce fichier.
let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

@main
enum ImportPipelineTests {
    static func main() {

// MARK: - t1 — Sniffing : le format vient des OCTETS, jamais de l'extension

print("t1 · Identification du format par les octets d'en-tête")
do {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 40))
    // LE bug de production : une capture partagée arrive nommée `<uuid>.dat`.
    // Sans sniffing elle tombait en « texte », et le décodage Latin-1 — qui
    // n'échoue jamais — produisait des centaines de milliers de caractères de
    // binaire envoyés au modèle.
    expect(ImportFormatSniffer.detect(data: png, fileExtension: "dat") == .image,
           "PNG nommé .dat reconnu comme image")
    // Et l'inverse : une extension mensongère ne doit pas primer non plus.
    expect(ImportFormatSniffer.detect(data: png, fileExtension: "csv") == .image,
           "PNG nommé .csv reste une image")

    let pdf = Data("%PDF-1.7\n%âãÏÓ\n".utf8)
    expect(ImportFormatSniffer.detect(data: pdf) == .pdf, "signature %PDF")

    let csv = Data("date;libelle;montant\n02/07/2026;CARREFOUR;-42,50\n".utf8)
    expect(ImportFormatSniffer.detect(data: csv) == .text, "CSV = texte")

    let camt = Data("<?xml version=\"1.0\"?><Document><BkToCstmrStmt/></Document>".utf8)
    expect(ImportFormatSniffer.detect(data: camt) == .xml, "CAMT reconnu comme XML")

    // OFX 1.x n'est PAS du XML : il commence par un bloc d'en-têtes SGML.
    let ofx = Data("OFXHEADER:100\nDATA:OFXSGML\n\n<OFX><SIGNONMSGSRSV1>".utf8)
    expect(ImportFormatSniffer.detect(data: ofx) == .xml, "OFX 1.x SGML rangé en XML")
    expect(ImportFormatSniffer.isOFX(ofx), "dialecte OFX distingué de CAMT")

    // Le NUL est le marqueur qui empêche un binaire de passer pour du texte.
    let binary = Data([0x00, 0x01, 0x02, 0x03] + Array(repeating: 0x41, count: 100))
    expect(ImportFormatSniffer.looksLikeText(binary) == false, "octet NUL → pas du texte")
    expect(ImportFormatSniffer.detect(data: binary) == .unknown, "binaire inconnu reste inconnu")

    expect(ImportFormatSniffer.detect(data: Data(), fileExtension: "pdf") == .pdf,
           "fichier vide → repli sur l'extension")

    // Un ZIP quelconque n'est pas un classeur : la signature ne suffit pas.
    let plainZip = Data([0x50, 0x4B, 0x03, 0x04] + Array("photos/img.png".utf8))
    expect(ImportFormatSniffer.detect(data: plainZip) == .unknown,
           "ZIP sans marqueur OOXML n'est pas un classeur")
}

// MARK: - t2 — Lecture ZIP

print("")
print("t2 · Lecture d'archive ZIP (STORE et DEFLATE)")
do {
    let archive = try! Data(contentsOf: fixturesDirectory.appendingPathComponent("statement_fixture.xlsx"))

    expect(ImportFormatSniffer.detect(data: archive, fileExtension: "") == .spreadsheet,
           "classeur reconnu par son contenu OOXML")

    switch ZIPArchiveReader.entries(in: archive) {
    case .failure(let error):
        expect(false, "listing des entrées", error.reason)
    case .success(let entries):
        expect(entries.count == 5, "5 entrées listées", "\(entries.count)")
        expect(entries.contains { $0.name == "xl/sharedStrings.xml" }, "chaînes partagées présentes")
        // Le répertoire central est lu en fin d'archive, pas les en-têtes
        // locaux : c'est ce qui garantit des tailles réelles même quand
        // l'archive a été écrite en flux.
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

print("")
print("t3 · Classeur XLSX → table commune")
do {
    let archive = try! Data(contentsOf: fixturesDirectory.appendingPathComponent("statement_fixture.xlsx"))

    switch XLSXReader.grids(from: archive) {
    case .failure(let error):
        expect(false, "lecture du classeur", error.reason)
    case .success(let grids):
        expect(grids.count == 2, "2 feuilles lues", "\(grids.count)")
        guard let sheet = grids.first else { break }

        expect(sheet.sheetName == "Operations", "nom d'onglet repris", sheet.sheetName ?? "nil")
        // Le bloc d'identité en tête (« RELEVE DE COMPTE », IBAN) ne doit pas
        // être pris pour l'en-tête : la table ferait une seule colonne.
        expect(sheet.hasExplicitHeader, "vraie ligne d'en-tête trouvée sous le bloc d'identité")
        expect(sheet.headers == ["Date", "Libelle", "Montant", "Devise"],
               "en-têtes lus depuis les chaînes partagées", "\(sheet.headers)")
        expect(sheet.rows.count == 3, "3 lignes de données", "\(sheet.rows.count)")
        expect(sheet.isTabular, "table exploitable par l'écran de mapping")

        if sheet.rows.count == 3 {
            // Excel stocke les dates en numéro de série ; sans conversion la
            // colonne arrive en « 45845 » et aucun format ne la reconnaît.
            expect(sheet.rows[0][0] == "2025-07-02",
                   "série Excel convertie en date", sheet.rows[0][0])
            // Une chaîne partagée coupée par un run de mise en forme doit être
            // recollée, sinon le libellé est tronqué au 1er changement de style.
            expect(sheet.rows[0][1] == "CARREFOUR MARKET PARIS",
                   "runs `<r><t>` concaténés", sheet.rows[0][1])
            expect(sheet.rows[0][2] == "-42.5", "montant brut conservé", sheet.rows[0][2])
            expect(sheet.rows[0][3] == "EUR", "chaîne inline lue", sheet.rows[0][3])

            // ⚠️ LE piège des tableurs : une cellule vide n'est PAS écrite dans
            // le XML. Sans lire la référence `r`, tout se décale à gauche — ici
            // « EUR » remonterait en colonne Montant pour toute la suite.
            expect(sheet.rows[2].count >= 4, "ligne à trou conservée à 4 colonnes",
                   "\(sheet.rows[2].count)")
            expect(sheet.rows[2][1] == "PRLV EDF", "libellé en place", sheet.rows[2][1])
            expect(sheet.rows[2][2] == "", "cellule absente rendue vide, pas décalée",
                   sheet.rows[2][2])
            expect(sheet.rows[2][3] == "EUR", "colonne suivante NON décalée", sheet.rows[2][3])
        }
    }

    // Tri des feuilles : lexicographiquement, sheet10 passerait avant sheet2.
    expect(XLSXReader.sheetIndex("xl/worksheets/sheet2.xml")
           < XLSXReader.sheetIndex("xl/worksheets/sheet10.xml"),
           "feuilles triées numériquement, pas lexicographiquement")

    // Références de colonnes OOXML.
    expect(XLSXCellReference.columnIndex(from: "A1") == 0, "A → 0")
    expect(XLSXCellReference.columnIndex(from: "D7") == 3, "D → 3")
    expect(XLSXCellReference.columnIndex(from: "AA1") == 26, "AA → 26")
    expect(XLSXCellReference.columnIndex(from: "BC12") == 54, "BC → 54")

    // Le décalage de 25 569 jours intègre le 29 février 1900 fictif d'Excel.
    let date = XLSXCellReference.date(fromSerial: 45840)
    expect(date.map { XLSXCellReference.isoFormatter.string(from: $0) } == "2025-07-02",
           "époque Excel (bissextile 1900 comprise)")
    // Point d'ancrage de la constante : la série 25569 EST le 1er janvier 1970.
    expect(XLSXCellReference.date(fromSerial: 25569)
            .map { XLSXCellReference.isoFormatter.string(from: $0) } == "1970-01-01",
           "série 25569 = époque Unix")
    expect(XLSXCellReference.date(fromSerial: 0) == nil, "série invalide rejetée")
}

// MARK: - t4 — CAMT.053

print("")
print("t4 · Relevé CAMT.053 (ISO 20022)")
do {
    // Préfixe de namespace VOLONTAIRE (`ns2:`) : les producteurs réels en
    // mettent, et comparer le nom qualifié complet ferait échouer le parsing
    // sur la moitié des fichiers.
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
        // ⚠️ CAMT écrit TOUJOURS un montant positif : le signe vient de
        // `CdtDbtInd`. Lire le nombre seul importerait un débit en recette.
        expect(debit.amount == -42.50, "DBIT → montant négatif", "\(debit.amount)")
        // Le `<Amt>` de 45,00 des détails (montant avant frais) ne doit PAS
        // écraser celui de l'écriture.
        expect(abs(debit.amount) == 42.50, "montant de l'écriture, pas celui des détails")
        expect(debit.label == "ACHAT CB 01/07", "libellé depuis RmtInf/Ustrd", debit.label)
        expect(debit.isSignExplicit, "signe déclaré par le format, pas déduit")
        expect(debit.confidence == 1.0, "confiance maximale sur un format nommé")

        expect(credit.amount == 2350.0, "CRDT → montant positif", "\(credit.amount)")
        expect(credit.label == "VIR SEPA SALAIRE ACME",
               "repli sur AddtlNtryInf quand RmtInf est absent", credit.label)
    }

    // Une écriture sans date ni montant ne doit produire AUCUNE ligne :
    // le moteur n'invente pas.
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

print("")
print("t5 · Relevé OFX (SGML 1.x et XML 2.0)")
do {
    // OFX 1.x : balises NON fermées. `XMLParser` rejette ce document en bloc,
    // d'où le tokenizer tolérant — et c'est le dialecte le plus répandu.
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
        // ⚠️ En OFX, contrairement à CAMT, le signe est DANS le nombre.
        expect(first.amount == -42.50, "signe porté par le nombre", "\(first.amount)")
        expect(first.label == "CARREFOUR MARKET — ACHAT CB 01/07",
               "NAME et MEMO combinés", first.label)
        expect(first.paymentTypeHint == "CB", "POS → CB", first.paymentTypeHint ?? "nil")

        expect(second.amount == 2350.0, "crédit positif", "\(second.amount)")
        expect(second.paymentTypeHint == "VIREMENT", "DIRECTDEP → VIREMENT",
               second.paymentTypeHint ?? "nil")

        // ⚠️ Un remboursement est un `DEBIT` au montant POSITIF. Forcer le
        // signe d'après TRNTYPE l'inverserait — d'où la règle « le nombre fait
        // foi » en OFX.
        expect(third.amount == 18.90, "DEBIT positif conservé positif", "\(third.amount)")
        expect(third.label == "REMBOURSEMENT MUTUELLE", "MEMO absent → NAME seul", third.label)
    }

    // OFX 2.0 : même contenu, en XML bien formé. Le même tokenizer doit
    // l'absorber sans branche dédiée.
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

    // OFX de courtier : les ordres de bourse ressortent en payload
    // investissement, sans passer par l'ancrage ISIN ni par l'IA.
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
            // ⚠️ Un dividende n'a NI quantité NI cours : exiger `UNITS > 0`
            // comme pour les autres ferait disparaître toutes les lignes de
            // revenu, qui ne portent que le total.
            expect(orders[1].orderType == "DIV", "INCOME → DIV", orders[1].orderType)
            expect(orders[1].unitPrice == 34.53, "dividende valorisé par son total",
                   "\(orders[1].unitPrice)")
        }
    } else {
        expect(false, "2 ordres depuis un OFX de courtier")
    }

    // Un XML qui n'est ni CAMT ni OFX doit être refusé PROPREMENT, jamais
    // interprété au hasard.
    switch LedgerXMLReader.parse(text: "<?xml version=\"1.0\"?><catalog><item/></catalog>") {
    case .success: expect(false, "XML étranger refusé")
    case .failure: expect(true, "XML étranger refusé")
    }
}

// MARK: - t6 — Modèle d'échange

print("")
print("t6 · ImportElement : agrégation par source et inspection")
do {
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
            // Une source qui n'a RIEN produit : c'est précisément celle qu'il
            // faut voir dans le détail par source, et qu'un total agrégé cache.
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

    // Inspection de debug : sur la structure NORMALISÉE, pas sur du texte OCR —
    // c'est le seul format qui couvre aussi CSV, classeur et XML.
    let json = result.debugJSON(sourceIndex: 0)
    expect(json.contains("CARREFOUR"), "JSON de debug produit")
    expect(json.contains("releve.pdf"), "origine tracée dans le JSON")
    expect(!json.contains("capture.png"), "filtre par source respecté")

    // Le confidence remonte du payload sans avoir à le déballer.
    expect(result.elements[0].confidence == 0.9, "confiance reprise du payload",
           "\(result.elements[0].confidence)")
    expect(result.elements[0].kind == .transaction, "type d'élément exposé")
}

// MARK: - t7 — Fusion de deux passes

print("")
print("t7 · Fusion de deux passes (CSV mappés, puis documents analysés)")
do {
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
    // ⚠️ Sans renumérotation, les deux passes repartent à sourceIndex 0 et
    // unitNumber 1 : l'agrégation par source les fusionnerait en UNE seule
    // source, et un rapport d'échec désignerait une unité ambiguë.
    expect(merged.perSource().count == 2, "sources restées distinctes",
           "\(merged.perSource().count)")
    expect(merged.units.map(\.origin.unitNumber) == [1, 2], "unités renumérotées à la suite",
           "\(merged.units.map(\.origin.unitNumber))")
    expect(merged.elements.map(\.origin.sourceIndex) == [0, 1], "sources renumérotées",
           "\(merged.elements.map(\.origin.sourceIndex))")
}

// MARK: - t8 — Table commune CSV / classeur

print("")
print("t8 · CSV et classeur produisent la MÊME table")
do {
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

    // Une source à UNE colonne n'est pas un tableau : l'envoyer au mapping
    // demanderait de désigner des colonnes inexistantes.
    let prose = "RELEVE DE COMPTE\nLe 2 juillet, achat CARREFOUR de 42,50 EUR\n"
    let proseGrid = CSVParser.parse(content: prose)
    expect(proseGrid?.isTabular != true, "texte en prose non traité comme une table")

    // Séparateur imposé par l'utilisateur : l'autodétection se trompe sur les
    // fichiers dont les libellés contiennent des virgules.
    let ambiguous = "Date,Libelle,Montant\n02/07/2026,\"CARREFOUR, PARIS\",-42.50"
    let forced = CSVParser.parse(content: ambiguous, forcedSeparator: ",")
    expect(forced?.rows.first?.count == 3, "guillemets respectés avec séparateur imposé",
           "\(forced?.rows.first?.count ?? -1)")
    expect(forced?.rows.first?[1] == "CARREFOUR, PARIS", "virgule protégée par les guillemets",
           forced?.rows.first?[1] ?? "nil")

    // Guillemets ÉCHAPPÉS (`""` dans un champ). L'import d'investissements
    // avait son propre découpage, qui basculait `inQuotes` à chaque guillemet
    // et cassait donc sur ce cas — il passe désormais par ce parseur.
    let escaped = CSVParser.parse(content: "libelle;montant\n\"dit \"\"bonjour\"\"\";2")
    expect(escaped?.rows.first?[0] == "dit \"bonjour\"", "guillemet échappé préservé",
           escaped?.rows.first?[0] ?? "nil")

    // Montants : les pièges qui faisaient rejeter des lignes valides.
    expect(CSVParser.parseAmount("1 234,56", decimal: ",") == 1234.56,
           "séparateur de milliers (espace)")
    expect(CSVParser.parseAmount("1\u{00A0}234,56", decimal: ",") == 1234.56,
           "espace INSÉCABLE des milliers")
    expect(CSVParser.parseAmount("1,234.56", decimal: ".") == 1234.56,
           "convention anglo-saxonne")
    expect(CSVParser.parseAmount("(42,50)", decimal: ",") == -42.50,
           "négatif comptable entre parenthèses")
}

// MARK: - t9 — Payload de session discriminé par la destination

print("")
print("t9 · Session : le contenu de rows_json dépend de la destination")
do {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // Transactions : [ImportSessionRow], qui porte l'état de RÉSOLUTION.
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

    // ⚠️ Le comptage des lignes en attente se fait par SCAN DE CHAÎNE, pas par
    // décodage (coût sur une grosse session). Si la représentation de l'enum
    // change, ce scan devient silencieusement faux — d'où cette vérification
    // du littéral exact attendu.
    var pending = ImportSessionRow(sourceRowNumber: 2, rawLabel: "EDF",
                                   date: Date(), amount: -89.9)
    pending.userAction = .pending
    let pendingJSON = String(decoding: try! encoder.encode([pending]), as: UTF8.self)
    expect(pendingJSON.contains("\"userAction\":\"pending\""),
           "littéral scanné par countPending inchangé")

    // Investissements : ImportBatchResult, sans état de résolution.
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

    // Les deux formes ne sont PAS interchangeables : c'est bien la colonne
    // `destination` qui doit trancher, jamais une tentative de décodage.
    expect((try? decoder.decode([ImportSessionRow].self, from: batchJSON)) == nil,
           "un lot ne se décode pas comme des lignes")
    expect((try? decoder.decode(ImportBatchResult.self, from: rowsJSON)) == nil,
           "des lignes ne se décodent pas comme un lot")
}

// MARK: - t10 — Encodage : le BOM prime sur toute heuristique

print("")
print("t10 · Décodage texte, UTF-16 compris")
do {
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

    // ⚠️ LA régression : un CSV UTF-16 big-endian décodé en little-endian
    // produit des idéogrammes CJK (« date » → 搀愀琀攀). Le fichier devenait
    // illisible, donc plus tabulaire, donc envoyé à l'IA au lieu du parseur
    // déterministe — d'où les caractères chinois ET la lenteur sur un CSV.
    let beWithBOM = utf16Data(bigEndian: true, bom: true)
    expect(ImportFormatSniffer.decodeText(beWithBOM)?.contains("CARREFOUR") == true,
           "UTF-16 BE avec BOM décodé correctement",
           ImportFormatSniffer.decodeText(beWithBOM).map { String($0.prefix(20)) } ?? "nil")
    expect(ImportFormatSniffer.decodeText(beWithBOM)?.contains("\u{6400}") == false,
           "aucun idéogramme parasite")

    let leWithBOM = utf16Data(bigEndian: false, bom: true)
    expect(ImportFormatSniffer.decodeText(leWithBOM)?.contains("CARREFOUR") == true,
           "UTF-16 LE avec BOM décodé correctement")

    // Sans BOM : la position des octets nuls donne le boutisme.
    expect(ImportFormatSniffer.decodeText(utf16Data(bigEndian: true, bom: false))?
            .contains("CARREFOUR") == true, "UTF-16 BE sans BOM deviné")
    expect(ImportFormatSniffer.decodeText(utf16Data(bigEndian: false, bom: false))?
            .contains("CARREFOUR") == true, "UTF-16 LE sans BOM deviné")

    // Un BOM UTF-16 est une déclaration explicite : c'est du texte, malgré les
    // octets nuls qui feraient échouer le test générique.
    expect(ImportFormatSniffer.looksLikeText(beWithBOM), "BOM UTF-16 reconnu comme texte")
    expect(ImportFormatSniffer.detect(data: beWithBOM) == .text, "UTF-16 sans extension → texte")

    // Et le CSV redevient TABULAIRE, donc ne part plus à l'IA.
    if let text = ImportFormatSniffer.decodeText(beWithBOM),
       let grid = CSVParser.parse(content: text) {
        expect(grid.isTabular, "CSV UTF-16 exploitable par le mapping (donc pas d'IA)")
        expect(grid.headers.count == 3, "3 colonnes", "\(grid.headers.count)")
    } else {
        expect(false, "CSV UTF-16 exploitable par le mapping (donc pas d'IA)")
    }

    // Non-régression : l'UTF-8 ordinaire n'est pas pris pour de l'UTF-16.
    expect(ImportFormatSniffer.decodeText(Data(csv.utf8))?.contains("CARREFOUR") == true,
           "UTF-8 sans BOM inchangé")
    let utf8BOM = Data([0xEF, 0xBB, 0xBF] + Array(csv.utf8))
    expect(ImportFormatSniffer.decodeText(utf8BOM)?.hasPrefix("date") == true,
           "BOM UTF-8 retiré")
}

// MARK: - t11 — JSON de modèle : réparation de mise en forme

print("")
print("t11 · Réparation d'un JSON coupé par la mise en forme")
do {
    // ⚠️ Cas RÉEL : le modèle a coupé le nom d'une clé sur deux lignes. C'est du
    // JSON invalide (caractère de contrôle brut dans une chaîne), `JSONDecoder`
    // lève, et TOUT le document est perdu — huit opérations correctement
    // extraites donnaient « aucune transaction à importer ».
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

    // Une VALEUR coupée se recolle avec une espace : c'est un libellé dont les
    // mots ont été séparés, pas un identifiant.
    let wrappedValue = """
    {"transactions":[{"label":"CARREFOUR
        CITY PARIS","amount":-1.0,"date":"2026-07-22"}]}
    """
    let fixedValue = LenientJSON.repaired(wrappedValue)
    expect(fixedValue.contains("CARREFOUR CITY PARIS"),
           "libellé recollé avec une espace",
           fixedValue.contains("CARREFOURCITY") ? "mots collés" : String(fixedValue.prefix(60)))

    // Non-régression : un JSON valide traverse inchangé, échappements compris.
    let valid = #"{"label":"dit \"bonjour\"","n":1}"#
    expect(LenientJSON.repaired(valid) == valid, "JSON valide inchangé",
           LenientJSON.repaired(valid))

    // Les balises de code que les modèles ajoutent sont retirées.
    let fenced = "```json\n" + #"{"a":1}"# + "\n```"
    expect(LenientJSON.extractObject(from: fenced) == #"{"a":1}"#,
           "balises de code retirées", LenientJSON.extractObject(from: fenced))

    // ⚠️ On ne referme RIEN : une structure tronquée doit rester une erreur
    // visible, pas une donnée devinée.
    let truncated = #"{"transactions":[{"label":"X""#
    expect((try? JSONSerialization.jsonObject(
                with: Data(LenientJSON.repaired(truncated).utf8))) == nil,
           "JSON tronqué reste invalide (rien n'est inventé)")
}

// MARK: - t12 — Une faute de syntaxe ne coûte qu'UNE ligne

print("")
print("t12 · Décodage objet par objet d'une réponse fautive")
do {
    // ⚠️ JSON RÉEL renvoyé par un modèle sur une capture d'appli bancaire.
    // Deux fautes de ponctuation : une virgule finale (3ᵉ objet) et un
    // guillemet ouvrant de clé oublié précédé d'une virgule parasite (8ᵉ).
    // Le décodage du DOCUMENT ENTIER échouait, donc les huit opérations
    // étaient perdues — dont six parfaitement formées.
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

    // Le document entier reste invalide — on ne prétend pas le contraire.
    expect((try? JSONSerialization.jsonObject(with: Data(response.utf8))) == nil,
           "le document brut est bien invalide (précondition)")

    let objects = LenientJSON.innermostObjects(in: response)
    expect(objects.count == 8, "8 objets isolés malgré les fautes", "\(objects.count)")

    let decoded = objects.compactMap { object -> [String: Any]? in
        guard let data = object.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    // Les DEUX fautes sont de la ponctuation réparable : on récupère tout.
    expect(decoded.count == 8, "8 opérations décodées", "\(decoded.count)")
    expect(decoded.compactMap { $0["label"] as? String }.contains("Terrys Cafe"),
           "libellé conservé")
    expect(decoded.compactMap { $0["amount"] as? Double }.contains(-6.98),
           "l'objet à virgule finale est récupéré")
    expect(decoded.compactMap { $0["amount"] as? Double }.contains(-6.00),
           "l'objet à guillemet manquant est récupéré")

    // Réparations prises une par une.
    expect(LenientJSON.repairSyntax(#"{"a":1,}"#) == #"{"a":1}"#,
           "virgule finale retirée", LenientJSON.repairSyntax(#"{"a":1,}"#))
    expect(LenientJSON.repairSyntax(#"{"a":1,, "b":2}"#).contains(#""b":2"#),
           "virgule dupliquée absorbée")
    expect(LenientJSON.repairSyntax(#"{"a":1, b": 2}"#).contains(#""b": 2"#),
           "guillemet ouvrant de clé restauré", LenientJSON.repairSyntax(#"{"a":1, b": 2}"#))

    // ⚠️ Non-régression : le contenu d'une CHAÎNE ne doit pas être touché par
    // les réparations de ponctuation.
    let withComma = #"{"label":"CARREFOUR, PARIS","amount":-1}"#
    expect(LenientJSON.repairSyntax(withComma) == withComma,
           "virgule dans un libellé préservée", LenientJSON.repairSyntax(withComma))

    // Un objet irrécupérable ne fait perdre QUE lui.
    let partlyBroken = #"[{"date":"2026-07-01","label":"OK","amount":-1},{"date":BROKEN}]"#
    let salvaged = LenientJSON.innermostObjects(in: partlyBroken).compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
    expect(salvaged.count == 1, "l'objet valide survit à son voisin cassé", "\(salvaged.count)")
    expect(salvaged.first?["label"] as? String == "OK", "et c'est le bon")
}

// MARK: - t13 — Virgule FR comme séparateur décimal dans un nombre

print("\nt13 · Virgule décimale FR dans un nombre JSON (\"amount\":-19,50)")
do {
    expect(LenientJSON.repairSyntax(#"{"amount":-19,50}"#) == #"{"amount":-19.50}"#,
           "négatif corrigé", LenientJSON.repairSyntax(#"{"amount":-19,50}"#))
    expect(LenientJSON.repairSyntax(#"{"amount":19,50}"#) == #"{"amount":19.50}"#,
           "positif corrigé", LenientJSON.repairSyntax(#"{"amount":19,50}"#))
    // Le vrai séparateur de champ suivant reste intact : la virgule qui
    // introduit "payment_type" n'a pas de chiffre juste après, le motif ne
    // la touche donc jamais.
    let field = #"{"amount":-19,50,"payment_type":null}"#
    expect(LenientJSON.repairSyntax(field) == #"{"amount":-19.50,"payment_type":null}"#,
           "séparateur de champ suivant intact", LenientJSON.repairSyntax(field))
    // Un entier suivi d'un champ qui COMMENCE par un chiffre n'est pas une
    // fausse décimale (ex. deux champs numériques consécutifs) : ancré
    // juste après ":", jamais après une autre valeur.
    expect(LenientJSON.repairSyntax(#"{"quantity":4,"amount":-19,50}"#)
               == #"{"quantity":4,"amount":-19.50}"#,
           "un entier voisin n'est pas confondu avec une décimale")

    // Réplique du cas réel : 9 opérations, décimales FR sur 4 d'entre elles,
    // aucune n'est perdue une fois réparées.
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

// MARK: - Bilan

print("")
if failures == 0 {
    print("✅ \(checks) assertions, 0 échec")
} else {
    print("❌ \(failures) échec(s) sur \(checks) assertions")
    exit(1)
}

    }
}
