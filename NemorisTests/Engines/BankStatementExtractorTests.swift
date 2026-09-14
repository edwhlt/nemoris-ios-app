import Foundation
import Testing

@testable import Nemoris

/// Deterministic extraction of operations from a bank statement.
///
/// Anchoring is done on the DATE, a statement having no equivalent of
/// the ISIN. The traps locked down here all come from real-world text: a
/// dotted date read as an amount, a thousands separator that silently
/// amputates a thousand, and "TOTAL" that can't be a summary-line
/// marker — TOTALENERGIES is a common merchant.
@Suite("Extraction de relevés bancaires")
struct BankStatementExtractorEngineTests {

    // These helpers propagate the caller's location: without it,
    // every failure would point here instead of at the actual test.
    private func expect(_ condition: Bool, _ label: String, _ detail: String = "",
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label)\(detail.isEmpty ? "" : " — \(detail)")",
                sourceLocation: sourceLocation)
    }


    // A harness without XCTest — compiles the REAL engine files
    // (see run_bank_statement_tests.sh).
    // Run after any change to `BankStatementExtractor`.




    // MARK: - t1 — A French tabular statement with a balance column

    @Test("Relevé PDF tabulaire (débit/crédit + solde courant)")
    func t1() throws {
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
            // The BALANCE column is last: taking the last amount
            // would import the account balance (1,457.50) instead of the operation.
            expect(abs(tx[0].amount + 42.50) < 0.001, "montant = colonne opération, pas le solde", "\(tx[0].amount)")
            expect(tx[0].label.contains("CARREFOUR MARKET"), "libellé conservé", tx[0].label)
            expect(tx[0].paymentTypeHint == "CB", "type CB déduit", tx[0].paymentTypeHint ?? "nil")

            // No sign on the number: the label decides.
            expect(tx[1].amount > 0, "VIR RECU SALAIRE reconnu comme crédit", "\(tx[1].amount)")
            expect(abs(tx[1].amount - 2350.0) < 0.001, "séparateur de milliers (espace) lu", "\(tx[1].amount)")
            expect(tx[1].paymentTypeHint == "VIREMENT", "type VIREMENT déduit", tx[1].paymentTypeHint ?? "nil")

            expect(tx[2].amount < 0, "prélèvement = dépense par défaut", "\(tx[2].amount)")
            expect(tx[2].paymentTypeHint == "PRELEVEMENT", "type PRELEVEMENT déduit", tx[2].paymentTypeHint ?? "nil")
            expect(tx.allSatisfy { !$0.isSignExplicit }, "signes marqués comme déduits (pas explicites)")
        }
    }

    // MARK: - t2 — An app screenshot (column-based OCR)

    @Test("Capture d'appli bancaire (un champ par ligne, libellé au-dessus)")
    func t2() throws {
        // The order observed in screenshots: merchant → date → signed amount.
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
            // The next-block trap: without a bound, block 2's label could
            // reach up to block 1's amount, or steal block 3's.
            expect(tx[1].label == "SNCF CONNECT", "libellé du 2e bloc non contaminé", tx[1].label)
            expect(abs(tx[1].amount + 89.00) < 0.001, "montant du 2e bloc correct", "\(tx[1].amount)")
            expect(tx[2].amount > 0, "« + » explicite = crédit", "\(tx[2].amount)")
            expect(tx[2].label.contains("MARTIN"), "libellé du virement conservé", tx[2].label)
        }
    }

    // MARK: - t3 — A dotted date doesn't become an amount

    @Test("« 02.07.2026 » n'est pas lu comme le montant 2,07")
    func t3() throws {
        let statement = """
        02.07.2026  ABONNEMENT SPOTIFY  -10,99
        """
        let tx = BankStatementExtractor.extractTransactions(from: statement)
        expect(tx.count == 1, "1 opération", "\(tx.count)")
        if let first = tx.first {
            expect(first.date == "2026-07-02", "date à points reconnue", first.date)
            // Without stripping dates beforehand, the amount pattern reads "02.07"
            // → 2.07, and the operation is imported with a wrong amount.
            expect(abs(first.amount + 10.99) < 0.001, "montant réel, pas un fragment de date", "\(first.amount)")
            expect(!first.label.contains("2026"), "date retirée du libellé", first.label)
        }
    }

    // MARK: - t4 — A short date inside the label doesn't anchor an operation

    @Test("« CARTE 01/07 » dans le libellé ne crée pas de seconde opération")
    func t4() throws {
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

    // MARK: - t5 — A label spanning several lines

    @Test("Libellé débordant sur la ligne suivante (mise en page tabulaire)")
    func t5() throws {
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

    @Test("Aucune invention sur un document sans opérations")
    func t6() throws {
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

        // An amount alone, with no date, isn't enough.
        let amountOnly = BankStatementExtractor.extractTransactions(from: "TOTAL A PAYER  128,40 €")
        expect(amountOnly.isEmpty, "montant sans date → rien", "\(amountOnly.count)")
    }

    // MARK: - t7 — "TOTALENERGIES" isn't a summary line

    @Test("Un marchand nommé TOTAL… n'est pas filtré comme total")
    func t7() throws {
        let statement = """
        08/07/2026 CARTE TOTALENERGIES STATION A10  -71,20
        """
        let tx = BankStatementExtractor.extractTransactions(from: statement)
        // A filter on the bare word "TOTAL" would remove this real operation.
        expect(tx.count == 1, "opération TOTALENERGIES conservée", "\(tx.count)")
        expect(tx.first?.label.contains("TOTALENERGIES") == true, "libellé intact", tx.first?.label ?? "nil")
    }

    // MARK: - t8 — Decimal conventions

    @Test("Virgule FR, point US, devise en suffixe")
    func t8() throws {
        let statement = """
        01/03/2026 ACHAT FR                        -1 234,56
        02/03/2026 SUBSCRIPTION US                 -1,234.56
        03/03/2026 SERVICE                         -49.99 USD
        """
        let tx = BankStatementExtractor.extractTransactions(from: statement)
        expect(tx.count == 3, "3 opérations", "\(tx.count)")
        if tx.count == 3 {
            expect(abs(tx[0].amount + 1234.56) < 0.001, "1 234,56 (FR) → 1234.56", "\(tx[0].amount)")
            // Both separators present: the LAST one is the decimal.
            expect(abs(tx[1].amount + 1234.56) < 0.001, "1,234.56 (US) → 1234.56", "\(tx[1].amount)")
            expect(abs(tx[2].amount + 49.99) < 0.001, "devise en suffixe tolérée", "\(tx[2].amount)")
        }
    }

    // MARK: - t9 — Types de paiement

    @Test("Détection du type de paiement")
    func t9() throws {
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
        // The order of the table matters: "RETRAIT DAB" also contains "CARTE" on
        // some statements ("RETRAIT CARTE DAB"), the withdrawal must win.
        expect(BankStatementExtractor.detectPaymentType(in: "RETRAIT CARTE DAB CIC") == "RETRAIT",
               "retrait prioritaire sur carte")
    }

    // MARK: - t10 — Confiance

    @Test("Confiance dégradée quand un champ est déduit")
    func t10() throws {
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

    // MARK: - t11 — A banking-app screenshot: dates with no year

    @Test("Dates d'appli bancaire (nom de mois, sans année, « Hier »)")
    func t11() throws {
        // A fixed reference date: the engine must stay deterministic.
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
        // Without this recognition, the deterministic pass returned 0 operations on an
        // app screenshot: the AI was left alone and the labels drifted.
        expect(tx.count == 4, "4 opérations extraites d'une capture d'appli", "\(tx.count)")
        if tx.count == 4 {
            expect(tx[0].label == "CARREFOUR MARKET GIF", "libellé, pas le mot de la date", tx[0].label)
            expect(tx[0].date == "2026-07-02", "« 2 juil. » → année déduite", tx[0].date)
            expect(tx[2].amount > 0, "crédit reconnu", "\(tx[2].amount)")
            expect(tx[3].label == "NETFLIX", "« Hier » ne devient pas le libellé", tx[3].label)
            expect(tx[3].date == "2026-08-03", "« Hier » résolu depuis la référence", tx[3].date)
        }

        // Deduced year: a date later than the reference belongs to the previous year.
        let december = BankStatementExtractor.extractTransactions(
            from: "SPOTIFY\n28 décembre\n-10,99 €", referenceDate: reference)
        expect(december.first?.date == "2025-12-28",
               "date future → année précédente (un relevé est historique)",
               december.first?.date ?? "nil")

        // The English "month day" form.
        let english = BankStatementExtractor.extractTransactions(
            from: "AMAZON\nJul 2\n-42.50", referenceDate: reference)
        expect(english.first?.date == "2026-07-02", "« Jul 2 » (mois avant jour)", english.first?.date ?? "nil")
    }

    // MARK: - t12 — A date with no year anchors ONLY on a pure date line

    @Test("« CARTE 01/07 » reste un libellé, « 01/07 » seul est une date")
    func t12() throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 4
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = cal.date(from: comps)!

        // A tabular line WITHOUT a full date: "01/07" there is the
        // card operation's date, not the statement's → no operation is invented.
        let inline = BankStatementExtractor.extractTransactions(
            from: "CARTE 01/07 BOULANGERIE DUPONT  -6,80", referenceDate: reference)
        expect(inline.isEmpty, "date courte noyée dans un libellé → pas d'ancre", "\(inline.count)")

        // The same date, alone on its own line (column layout) → a valid anchor.
        let column = BankStatementExtractor.extractTransactions(
            from: "BOULANGERIE DUPONT\n01/07\n-6,80 €", referenceDate: reference)
        expect(column.count == 1, "date courte seule sur sa ligne → ancre", "\(column.count)")
        expect(column.first?.date == "2026-07-01", "jour/mois FR", column.first?.date ?? "nil")

        // A word containing "hier" [French for "yesterday"] must not be mistaken for yesterday's date.
        let trap = BankStatementExtractor.extractTransactions(
            from: "FICHIER COMPTABLE\n-12,00 €", referenceDate: reference)
        expect(trap.isEmpty, "« FICHIER » n'est pas « hier »", "\(trap.count)")
    }

    // MARK: - t13 — An app screenshot with DATE HEADERS (several ops per day)

    @Test("En-tête de date groupant plusieurs opérations (marchand + catégorie + montant)")
    func t13() throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = cal.date(from: comps)!

        // A real-world layout: the day is announced ONCE, then the
        // operations follow one after another, each on three lines.
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
        // The "one date = one operation" model only kept one per day.
        expect(tx.count == 5, "toutes les opérations de chaque journée", "\(tx.count)")

        if tx.count == 5 {
            // The label is the FIRST line of the block (the merchant), not the
            // one closest to the amount — which is the category.
            expect(tx[0].label == "Carrefour City", "marchand, pas la catégorie", tx[0].label)
            expect(tx[1].label == "Amshc", "2e opération de la même journée", tx[1].label)
            expect(tx[0].date == tx[1].date, "les deux héritent de l'en-tête du 22", tx[1].date)
            expect(abs(tx[1].amount + 6.00) < 0.001, "montant du 2e bloc", "\(tx[1].amount)")
            expect(tx[3].label == "Image Numer Mede", "libellé non décalé d'un bloc", tx[3].label)
            expect(tx[4].label == "Lmw Billetweb", "dernière journée", tx[4].label)
        }
        // The navigation bar's title comes before the first header: it must
        // never become a label (the backward window is only used
        // for layouts where the merchant precedes the date).
        expect(!tx.contains { $0.label.contains("Retour Compte") },
               "le titre de l'écran n'est pas importé")
        expect(!tx.contains { $0.label.contains("/") && $0.label.contains("tabac") },
               "aucune catégorie prise pour un marchand")
    }

    // MARK: - t14 — Dates rendered by a MODEL, often out of format

    @Test("Normalisation des dates produites par un modèle")
    func t14() throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: comps)!

        func norm(_ raw: String) -> String? {
            BankStatementExtractor.normalizeDate(raw, referenceDate: ref)
        }

        // A REAL case: an app screenshot doesn't show the year, the model fills in a
        // placeholder. Rejecting the line discarded the whole extraction even though
        // the day and month were correct.
        expect(norm("22-07-00") == "2026-07-22", "année bidon → déduite", norm("22-07-00") ?? "nil")
        expect(norm("22/07") == "2026-07-22", "jour/mois nu → année déduite", norm("22/07") ?? "nil")
        expect(norm("2026-07-22") == "2026-07-22", "format demandé respecté", norm("2026-07-22") ?? "nil")
        expect(norm("22-07-2026") == "2026-07-22", "année en dernier", norm("22-07-2026") ?? "nil")
        // FR convention when the order is ambiguous (both components ≤ 12).
        // A case chosen in the PAST to exercise only the convention, without
        // layering in the year rule.
        expect(norm("03-04") == "2026-04-03", "ambigu → jour d'abord (FR)", norm("03-04") ?? "nil")
        // And if the ambiguity falls in the future, the year rule
        // applies as everywhere else: a statement is historical.
        expect(norm("07-08") == "2025-08-07", "ambigu + futur → année précédente", norm("07-08") ?? "nil")
        // Detectably English: the second component can't be a month.
        expect(norm("07-22-2026") == "2026-07-22", "mois-jour quand le 2e > 12", norm("07-22-2026") ?? "nil")
        // A date later than the reference belongs to the previous year.
        expect(norm("28-12") == "2025-12-28", "date future → année précédente", norm("28-12") ?? "nil")
        // No invention: whatever isn't a date stays rejected.
        expect(norm("2026-13-45") == nil, "mois/jour impossibles → rejet")
        expect(norm("Carrefour") == nil, "texte → rejet")
    }
}
