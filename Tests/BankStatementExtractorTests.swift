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

// MARK: - t11 — Capture d'appli bancaire : dates sans année

print("t11 · Dates d'appli bancaire (nom de mois, sans année, « Hier »)")
do {
    // Référence fixe : le moteur doit rester déterministe.
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 4
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let reference = cal.date(from: comps)!

    let ocr = """
    Compte courant
    Solde : 1 240,55 €
    CARREFOUR MARKET GIF
    2 juil.
    -42,50 €
    SNCF CONNECT
    1 juil.
    -89,00 €
    VIREMENT DE MME MARTIN
    30 juin
    +150,00 €
    NETFLIX
    Hier
    -15,99 €
    """
    let tx = BankStatementExtractor.extractTransactions(from: ocr, referenceDate: reference)
    // Sans cette reconnaissance, le déterministe rendait 0 opération sur une
    // capture d'appli : l'IA restait seule et les libellés dérivaient.
    expect(tx.count == 4, "4 opérations extraites d'une capture d'appli", "\(tx.count)")
    if tx.count == 4 {
        expect(tx[0].label == "CARREFOUR MARKET GIF", "libellé, pas le mot de la date", tx[0].label)
        expect(tx[0].date == "2026-07-02", "« 2 juil. » → année déduite", tx[0].date)
        expect(tx[2].amount > 0, "crédit reconnu", "\(tx[2].amount)")
        expect(tx[3].label == "NETFLIX", "« Hier » ne devient pas le libellé", tx[3].label)
        expect(tx[3].date == "2026-08-03", "« Hier » résolu depuis la référence", tx[3].date)
    }

    // Année déduite : une date postérieure à la référence appartient à l'an passé.
    let december = BankStatementExtractor.extractTransactions(
        from: "SPOTIFY\n28 décembre\n-10,99 €", referenceDate: reference)
    expect(december.first?.date == "2025-12-28",
           "date future → année précédente (un relevé est historique)",
           december.first?.date ?? "nil")

    // Forme anglo-saxonne « mois jour ».
    let english = BankStatementExtractor.extractTransactions(
        from: "AMAZON\nJul 2\n-42.50", referenceDate: reference)
    expect(english.first?.date == "2026-07-02", "« Jul 2 » (mois avant jour)", english.first?.date ?? "nil")
}

// MARK: - t12 — Une date sans année n'ancre QUE sur une ligne de date pure

print("t12 · « CARTE 01/07 » reste un libellé, « 01/07 » seul est une date")
do {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 4
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let reference = cal.date(from: comps)!

    // Ligne tabulaire SANS date complète : « 01/07 » y est la date de
    // l'opération carte, pas celle du relevé → aucune opération inventée.
    let inline = BankStatementExtractor.extractTransactions(
        from: "CARTE 01/07 BOULANGERIE DUPONT  -6,80", referenceDate: reference)
    expect(inline.isEmpty, "date courte noyée dans un libellé → pas d'ancre", "\(inline.count)")

    // Même date, seule sur sa ligne (mise en page colonne) → ancre valide.
    let column = BankStatementExtractor.extractTransactions(
        from: "BOULANGERIE DUPONT\n01/07\n-6,80 €", referenceDate: reference)
    expect(column.count == 1, "date courte seule sur sa ligne → ancre", "\(column.count)")
    expect(column.first?.date == "2026-07-01", "jour/mois FR", column.first?.date ?? "nil")

    // Un mot contenant « hier » ne doit pas être pris pour la date d'hier.
    let trap = BankStatementExtractor.extractTransactions(
        from: "FICHIER COMPTABLE\n-12,00 €", referenceDate: reference)
    expect(trap.isEmpty, "« FICHIER » n'est pas « hier »", "\(trap.count)")
}

// MARK: - t13 — Capture d'appli à EN-TÊTES DE DATE (plusieurs ops par journée)

print("t13 · En-tête de date groupant plusieurs opérations (marchand + catégorie + montant)")
do {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 5
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let reference = cal.date(from: comps)!

    // Mise en page réelle : la journée est annoncée UNE fois, puis les
    // opérations s'enchaînent, chacune sur trois lignes.
    let ocr = """
    11:05
    Retour Compte Courant Jeune Actif
    22 juillet
    Carrefour City
    Grande surface
    - 3,98 €
    Amshc
    Hébergement / restauration
    - 6,00 €
    21 juillet
    Carrefour City
    Grande surface
    - 6,98 €
    Image Numer Mede
    A catégoriser, divers
    - 28,56 €
    18 juillet
    Lmw Billetweb
    Sorties / restaurant
    - 6,00 €
    """
    let tx = BankStatementExtractor.extractTransactions(from: ocr, referenceDate: reference)
    // Le modèle « une date = une opération » n'en retenait qu'une par journée.
    expect(tx.count == 5, "toutes les opérations de chaque journée", "\(tx.count)")

    if tx.count == 5 {
        // Le libellé est la PREMIÈRE ligne du bloc (le marchand), pas la plus
        // proche du montant — qui est la catégorie.
        expect(tx[0].label == "Carrefour City", "marchand, pas la catégorie", tx[0].label)
        expect(tx[1].label == "Amshc", "2e opération de la même journée", tx[1].label)
        expect(tx[0].date == tx[1].date, "les deux héritent de l'en-tête du 22", tx[1].date)
        expect(abs(tx[1].amount + 6.00) < 0.001, "montant du 2e bloc", "\(tx[1].amount)")
        expect(tx[3].label == "Image Numer Mede", "libellé non décalé d'un bloc", tx[3].label)
        expect(tx[4].label == "Lmw Billetweb", "dernière journée", tx[4].label)
    }
    // Le titre de la barre de navigation précède le premier en-tête : il ne
    // doit jamais devenir un libellé (la fenêtre arrière n'est utilisée que
    // pour les mises en page où le marchand précède la date).
    expect(!tx.contains { $0.label.contains("Retour Compte") },
           "le titre de l'écran n'est pas importé")
    expect(!tx.contains { $0.label.contains("/") && $0.label.contains("tabac") },
           "aucune catégorie prise pour un marchand")
}

// MARK: - t14 — Dates rendues par un MODÈLE, souvent hors format

print("t14 · Normalisation des dates produites par un modèle")
do {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 5
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let ref = cal.date(from: comps)!

    func norm(_ raw: String) -> String? {
        BankStatementExtractor.normalizeDate(raw, referenceDate: ref)
    }

    // Cas RÉEL : une capture d'appli n'affiche pas l'année, le modèle met un
    // remplissage. Rejeter la ligne jetait toute l'extraction alors que le
    // jour et le mois étaient bons.
    expect(norm("22-07-00") == "2026-07-22", "année bidon → déduite", norm("22-07-00") ?? "nil")
    expect(norm("22/07") == "2026-07-22", "jour/mois nu → année déduite", norm("22/07") ?? "nil")
    expect(norm("2026-07-22") == "2026-07-22", "format demandé respecté", norm("2026-07-22") ?? "nil")
    expect(norm("22-07-2026") == "2026-07-22", "année en dernier", norm("22-07-2026") ?? "nil")
    // Convention FR quand l'ordre est ambigu (les deux composants ≤ 12).
    // Cas choisi dans le PASSÉ pour n'éprouver que la convention, sans
    // superposer la règle d'année.
    expect(norm("03-04") == "2026-04-03", "ambigu → jour d'abord (FR)", norm("03-04") ?? "nil")
    // Et si l'ambiguïté tombe dans le futur, la règle d'année s'applique
    // comme partout ailleurs : un relevé est historique.
    expect(norm("07-08") == "2025-08-07", "ambigu + futur → année précédente", norm("07-08") ?? "nil")
    // Anglo-saxon détectable : le second composant ne peut pas être un mois.
    expect(norm("07-22-2026") == "2026-07-22", "mois-jour quand le 2e > 12", norm("07-22-2026") ?? "nil")
    // Une date postérieure à la référence appartient à l'année précédente.
    expect(norm("28-12") == "2025-12-28", "date future → année précédente", norm("28-12") ?? "nil")
    // Non-invention : ce qui n'est pas une date reste rejeté.
    expect(norm("2026-13-45") == nil, "mois/jour impossibles → rejet")
    expect(norm("Carrefour") == nil, "texte → rejet")
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
