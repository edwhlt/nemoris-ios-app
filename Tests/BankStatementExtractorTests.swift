import Foundation

// Harness sans XCTest — compile les fichiers RÉELS des moteurs
// (cf. run_bank_statement_tests.sh).
// À lancer après toute modification de `BankStatementExtractor`.

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

@main
enum BankStatementExtractorTests {
    static func main() {

// MARK: - t1 — Relevé tabulaire français avec colonne solde

print("t1 · Relevé PDF tabulaire (débit/crédit + solde courant)")
do {
    let statement = """
    RELEVE DE COMPTE
    DATE       LIBELLE                              DEBIT     CREDIT    SOLDE
    ANCIEN SOLDE                                                       1 500,00
    02/07/2026 CARTE 01/07 CARREFOUR MARKET          42,50              1 457,50
    03/07/2026 VIR SEPA RECU SALAIRE ACME                     2 350,00  3 807,50
    05/07/2026 PRLV EDF FACTURE                      89,90              3 717,60
    NOUVEAU SOLDE                                                       3 717,60
    """
    let tx = BankStatementExtractor.extractTransactions(from: statement)
    expect(tx.count == 3, "3 opérations extraites, lignes de solde ignorées", "\(tx.count) trouvée(s)")

    if tx.count == 3 {
        expect(tx[0].date == "2026-07-02", "date normalisée", tx[0].date)
        // La colonne SOLDE est la dernière : prendre le dernier montant
        // importerait le solde du compte (1 457,50) à la place de l'opération.
        expect(abs(tx[0].amount + 42.50) < 0.001, "montant = colonne opération, pas le solde", "\(tx[0].amount)")
        expect(tx[0].label.contains("CARREFOUR MARKET"), "libellé conservé", tx[0].label)
        expect(tx[0].paymentTypeHint == "CB", "type CB déduit", tx[0].paymentTypeHint ?? "nil")

        // Aucun signe sur le nombre : c'est le libellé qui tranche.
        expect(tx[1].amount > 0, "VIR RECU SALAIRE reconnu comme crédit", "\(tx[1].amount)")
        expect(abs(tx[1].amount - 2350.0) < 0.001, "séparateur de milliers (espace) lu", "\(tx[1].amount)")
        expect(tx[1].paymentTypeHint == "VIREMENT", "type VIREMENT déduit", tx[1].paymentTypeHint ?? "nil")

        expect(tx[2].amount < 0, "prélèvement = dépense par défaut", "\(tx[2].amount)")
        expect(tx[2].paymentTypeHint == "PRELEVEMENT", "type PRELEVEMENT déduit", tx[2].paymentTypeHint ?? "nil")
        expect(tx.allSatisfy { !$0.isSignExplicit }, "signes marqués comme déduits (pas explicites)")
    }
}

// MARK: - t2 — Capture d'écran d'app (OCR en colonne)

print("t2 · Capture d'appli bancaire (un champ par ligne, libellé au-dessus)")
do {
    // Ordre observé dans les captures : marchand → date → montant signé.
    let ocr = """
    Mes opérations
    Juillet 2026
    CARREFOUR MARKET GIF
    27/07/2026
    -42,50 €
    SNCF CONNECT
    26/07/2026
    -89,00 €
    VIREMENT DE MME MARTIN
    25/07/2026
    +150,00 €
    """
    let tx = BankStatementExtractor.extractTransactions(from: ocr)
    expect(tx.count == 3, "3 opérations extraites en mise en page colonne", "\(tx.count) trouvée(s)")

    if tx.count == 3 {
        expect(tx[0].label == "CARREFOUR MARKET GIF", "libellé pris AU-DESSUS de la date", tx[0].label)
        expect(abs(tx[0].amount + 42.50) < 0.001, "montant de la ligne suivante rattaché", "\(tx[0].amount)")
        expect(tx[0].isSignExplicit, "signe explicite reconnu (« - » collé)")
        // Le piège du bloc suivant : sans borne, le libellé du bloc 2 pourrait
        // remonter jusqu'au montant du bloc 1 ou voler celui du bloc 3.
        expect(tx[1].label == "SNCF CONNECT", "libellé du 2e bloc non contaminé", tx[1].label)
        expect(abs(tx[1].amount + 89.00) < 0.001, "montant du 2e bloc correct", "\(tx[1].amount)")
        expect(tx[2].amount > 0, "« + » explicite = crédit", "\(tx[2].amount)")
        expect(tx[2].label.contains("MARTIN"), "libellé du virement conservé", tx[2].label)
    }
}

// MARK: - t3 — Date à points ne devient pas un montant

print("t3 · « 02.07.2026 » n'est pas lu comme le montant 2,07")
do {
    let statement = """
    02.07.2026  ABONNEMENT SPOTIFY  -10,99
    """
    let tx = BankStatementExtractor.extractTransactions(from: statement)
    expect(tx.count == 1, "1 opération", "\(tx.count)")
    if let first = tx.first {
        expect(first.date == "2026-07-02", "date à points reconnue", first.date)
        // Sans le strip préalable des dates, le motif de montant lit « 02.07 »
        // → 2,07, et l'opération est importée avec un montant faux.
        expect(abs(first.amount + 10.99) < 0.001, "montant réel, pas un fragment de date", "\(first.amount)")
        expect(!first.label.contains("2026"), "date retirée du libellé", first.label)
    }
}

// MARK: - t4 — Date courte dans le libellé n'ancre pas une opération

print("t4 · « CARTE 01/07 » dans le libellé ne crée pas de seconde opération")
do {
    let statement = """
    02/07/2026 CARTE 01/07 BOULANGERIE DUPONT  -6,80
    """
    let tx = BankStatementExtractor.extractTransactions(from: statement)
    expect(tx.count == 1, "une seule opération malgré deux dates apparentes", "\(tx.count)")
    if let first = tx.first {
        expect(first.date == "2026-07-02", "la date d'ancrage est la date complète", first.date)
        expect(abs(first.amount + 6.80) < 0.001, "montant correct", "\(first.amount)")
    }
}

// MARK: - t5 — Libellé sur plusieurs lignes

print("t5 · Libellé débordant sur la ligne suivante (mise en page tabulaire)")
do {
    let statement = """
    12/06/2026  PAIEMENT CB 1106                    -128,40
                AMAZON EU SARL LUXEMBOURG
    14/06/2026  PRLV FREE MOBILE                     -19,99
    """
    let tx = BankStatementExtractor.extractTransactions(from: statement)
    expect(tx.count == 2, "2 opérations", "\(tx.count)")
    if tx.count == 2 {
        expect(tx[0].label.contains("AMAZON"), "continuation rattachée au libellé", tx[0].label)
        expect(tx[0].label.contains("PAIEMENT CB"), "début du libellé conservé", tx[0].label)
        expect(abs(tx[1].amount + 19.99) < 0.001, "opération suivante intacte", "\(tx[1].amount)")
    }
}

// MARK: - t6 — Non-invention

print("t6 · Aucune invention sur un document sans opérations")
do {
    let noise = """
    BANQUE POPULAIRE
    Votre conseiller : M. Dupont
    Agence de Versailles
    Téléphone : 01 39 50 12 34
    IBAN FR76 1234 5678 9012 3456 7890 123
    """
    let tx = BankStatementExtractor.extractTransactions(from: noise)
    expect(tx.isEmpty, "0 opération sur un en-tête sans date+montant", "\(tx.count) inventée(s)")

    let empty = BankStatementExtractor.extractTransactions(from: "")
    expect(empty.isEmpty, "texte vide → tableau vide")

    // Un montant seul, sans date, ne suffit pas.
    let amountOnly = BankStatementExtractor.extractTransactions(from: "TOTAL A PAYER  128,40 €")
    expect(amountOnly.isEmpty, "montant sans date → rien", "\(amountOnly.count)")
}

// MARK: - t7 — « TOTALENERGIES » n'est pas une ligne de synthèse

print("t7 · Un marchand nommé TOTAL… n'est pas filtré comme total")
do {
    let statement = """
    08/07/2026 CARTE TOTALENERGIES STATION A10  -71,20
    """
    let tx = BankStatementExtractor.extractTransactions(from: statement)
    // Un filtre sur le mot « TOTAL » nu supprimerait cette opération réelle.
    expect(tx.count == 1, "opération TOTALENERGIES conservée", "\(tx.count)")
    expect(tx.first?.label.contains("TOTALENERGIES") == true, "libellé intact", tx.first?.label ?? "nil")
}

// MARK: - t8 — Conventions décimales

print("t8 · Virgule FR, point US, devise en suffixe")
do {
    let statement = """
    01/03/2026 ACHAT FR                        -1 234,56
    02/03/2026 SUBSCRIPTION US                 -1,234.56
    03/03/2026 SERVICE                         -49.99 USD
    """
    let tx = BankStatementExtractor.extractTransactions(from: statement)
    expect(tx.count == 3, "3 opérations", "\(tx.count)")
    if tx.count == 3 {
        expect(abs(tx[0].amount + 1234.56) < 0.001, "1 234,56 (FR) → 1234.56", "\(tx[0].amount)")
        // Les deux séparateurs présents : le DERNIER est le décimal.
        expect(abs(tx[1].amount + 1234.56) < 0.001, "1,234.56 (US) → 1234.56", "\(tx[1].amount)")
        expect(abs(tx[2].amount + 49.99) < 0.001, "devise en suffixe tolérée", "\(tx[2].amount)")
    }
}

// MARK: - t9 — Types de paiement

print("t9 · Détection du type de paiement")
do {
    let cases: [(String, String?)] = [
        ("RETRAIT DAB LA POSTE", "RETRAIT"),
        ("CHEQUE N 4512300", "CHEQUE"),
        ("CARTE 12/06 FNAC PARIS", "CB"),
        ("PRLV SEPA ORANGE SA", "PRELEVEMENT"),
        ("VIR INST DE M DUPONT", "VIREMENT"),
        ("COTISATION ANNUELLE", nil)
    ]
    for (label, expected) in cases {
        let got = BankStatementExtractor.detectPaymentType(in: label)
        expect(got == expected, "« \(label) » → \(expected ?? "nil")", got ?? "nil")
    }
    // L'ordre du tableau compte : « RETRAIT DAB » contient aussi « CARTE » sur
    // certains relevés (« RETRAIT CARTE DAB »), le retrait doit gagner.
    expect(BankStatementExtractor.detectPaymentType(in: "RETRAIT CARTE DAB CIC") == "RETRAIT",
           "retrait prioritaire sur carte")
}

// MARK: - t10 — Confiance

print("t10 · Confiance dégradée quand un champ est déduit")
do {
    let explicit = BankStatementExtractor.extractTransactions(
        from: "02/07/2026 ABONNEMENT NETFLIX -15,99")
    let deduced = BankStatementExtractor.extractTransactions(
        from: "02/07/2026 ABONNEMENT NETFLIX  15,99  1 200,00")
    expect(explicit.first != nil && deduced.first != nil, "les deux cas produisent une opération")
    if let e = explicit.first, let d = deduced.first {
        expect(e.confidence > d.confidence,
               "signe explicite + montant unique = plus confiant",
               "\(e.confidence) vs \(d.confidence)")
        expect(e.isSignExplicit && !d.isSignExplicit, "drapeau de signe cohérent")
        expect(abs(d.amount + 15.99) < 0.001, "colonne opération retenue face au solde", "\(d.amount)")
    }
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
