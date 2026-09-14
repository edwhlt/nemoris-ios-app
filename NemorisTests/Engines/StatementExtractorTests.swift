import Foundation
import Testing

@testable import Nemoris

/// Deterministic extraction of operations from an investment statement.
///
/// Anchoring is done on the ISIN, validated by its checksum — which
/// rules out internal bank references. Two distinct windows per
/// operation: fields are read AFTER the anchor, the name BEFORE. A single
/// window made block N inherit the previous block's fields.
@Suite("Extraction d'avis d'opéré")
struct InvestmentStatementExtractorEngineTests {

    // These helpers propagate the caller's location: without it,
    // every failure would point here instead of at the actual test.
    private func expect(_ condition: Bool, _ label: String, _ detail: String = "",
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label)\(detail.isEmpty ? "" : " — \(detail)")",
                sourceLocation: sourceLocation)
    }


    // A harness without XCTest — compiles the REAL engine file (see run_statement_extractor_tests.sh).
    // Run after any change to `InvestmentStatementExtractor`.




    // MARK: - t1 — An app screenshot (the case that failed in production)

    @Test("Capture Boursorama « Mes mouvements » (OCR en colonne)")
    func t1() throws {
        // Real OCR text: one field per line, order name → ISIN → operation → date.
        let ocr = """
        Mes mouvements
        Période
        04/05/2026 - 02/08/2026
        Type d'opération
        Toutes
        AM.PEA EM.ES.T.ACC
        FR0013412020
        ACHAT COMPTANT -
        27/07/2026
        -242,92 €
        Quantité: 7
        Cours: 34,53 €
        AM.SE600 TECHN.ACC
        LU1834988518
        ACHAT COMPTANT -
        27/07/2026
        -226,65 €
        Quantité: 2
        Cours: 112,76 €
        TOTALENERGIES SE
        FR0000120271
        COUPONS - 02/07/2026
        +1,70
        Quantité: 2
        THALES
        FR0000121329
        COUPONS - 18/05/2026
        +2,95
        Quantité: 1
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: ocr)
        expect(orders.count == 4, "4 opérations extraites sans IA", "\(orders.count) trouvée(s)")

        if let first = orders.first {
            expect(first.orderType == "BUY", "achat reconnu", first.orderType)
            expect(first.isin == "FR0013412020", "ISIN correct", first.isin)
            expect(first.assetName == "AM.PEA EM.ES.T.ACC", "nom du titre remonté au-dessus de l'ISIN", first.assetName)
            expect(first.quantity == 7, "quantité lue", "\(first.quantity)")
            expect(abs(first.unitPrice - 34.53) < 0.001, "cours lu (virgule décimale FR)", "\(first.unitPrice)")
            expect(first.executedAt == "2026-07-27", "date normalisée", first.executedAt)
        }
        // The next-block trap: without a line bound on labels, the
        // quantity of the next operation was being swallowed.
        if orders.count > 1 {
            expect(orders[1].quantity == 2, "quantité du 2e bloc non contaminée par le 1er", "\(orders[1].quantity)")
            expect(abs(orders[1].unitPrice - 112.76) < 0.001, "cours du 2e bloc", "\(orders[1].unitPrice)")
        }
        let coupons = orders.filter { $0.orderType == "DIV" }
        expect(coupons.count == 2, "les 2 coupons sont typés DIV", "\(coupons.count)")
        // A coupon with no displayed price → the unit price is deduced from amount / quantity.
        if let tte = orders.first(where: { $0.isin == "FR0000120271" }) {
            expect(abs(tte.unitPrice - 0.85) < 0.01, "cours du coupon déduit (1,70 / 2)", "\(tte.unitPrice)")
        }
    }

    // MARK: - t2 — A trade confirmation PDF (tabular format, one operation per page)

    @Test("Avis d'opéré Boursorama (PDF, libellés explicites)")
    func t2() throws {
        let pdf = """
        BOURSORAMA BANQUE
        Avis d'opéré
        EPARGNE MSCI WORLD UCITS ETF - EUR (C)
        Code ISIN : LU1681043599
        Nature de l'opération : Achat au marché
        Date d'exécution : 15/03/2024
        Quantité exécutée : 2,000
        Cours d'exécution : 485,30 EUR
        Commission : 1,99 EUR
        Montant net : -972,59 EUR
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: pdf)
        expect(orders.count == 1, "1 opération extraite", "\(orders.count)")
        if let o = orders.first {
            expect(o.orderType == "BUY", "achat reconnu")
            expect(o.isin == "LU1681043599", "ISIN correct", o.isin)
            expect(o.quantity == 2, "quantité « 2,000 » lue comme 2", "\(o.quantity)")
            expect(abs(o.unitPrice - 485.30) < 0.001, "cours d'exécution", "\(o.unitPrice)")
            expect(abs(o.fees - 1.99) < 0.001, "commission lue", "\(o.fees)")
            expect(o.executedAt == "2024-03-15", "date dd/MM/yyyy normalisée", o.executedAt)
            expect(o.assetName.contains("EPARGNE"), "nom du titre", o.assetName)
        }
    }

    // MARK: - t2bis — A real TABLE: the quantity arrives BEFORE the ISIN

    @Test("Avis d'opéré en tableau (quantité alignée avec la date, avant l'ISIN)")
    func t2bis() throws {
        // ⚠️ A reproduction of the text as PDFKit flattens it for a REAL table
        // (not a "label: value" line-by-line format like t2). The security's
        // name and ISIN occupy TWO sub-lines of their cell, while the
        // quantity — in the neighboring cell, aligned with the first sub-line
        // (the date) — ends up BEFORE the ISIN in the linear text, with
        // other document lines in between. A real bug: without a fallback to the
        // window BEFORE for numeric fields (not just the date), the
        // quantity stayed unfindable — replaced by 1, which also skewed the
        // total amount (€50 instead of €200).
        let pdf = """
        Références de votre compte titres
        40618 80314 00088441579 Compte PEA
        Résident Français
        ACHAT COMPTANT ETR
        ACTION
        Date et heure
        locale d'exécution Quantité Informations sur la valeur Informations sur l'exécution
        13/01/2025 4 ISHS CO.EURO STOX50 UC.ETF EUR Référence : 170187650594
        12:11:59 Code ISIN : IE0008471009 Type d'ordre : à cours limité
        Cours demandé : 50,0000 EUR
        Cours exécuté : 50,00 EUR
        Lieu d'exécution : EURONEXT AMSTERDAM
        Montant transaction brut Intérêts Montant transaction total brut Courtages Montant transaction net
        200,00 EUR 0,00 EUR 200,00 EUR 0,00 EUR 0,00 EUR
        Montant net au débit de votre compte
        200,00 EUR
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: pdf)
        expect(orders.count == 1, "1 opération extraite", "\(orders.count)")
        if let o = orders.first {
            expect(o.orderType == "BUY", "achat comptant reconnu")
            expect(o.isin == "IE0008471009", "ISIN correct", o.isin)
            expect(o.quantity == 4, "quantité lue AVANT l'ISIN (bug réel)", "\(o.quantity)")
            expect(abs(o.unitPrice - 50.0) < 0.001, "cours exécuté (pas le cours demandé)",
                   "\(o.unitPrice)")
            expect(o.executedAt == "2025-01-13", "date lue", o.executedAt)
            expect(abs(o.quantity * o.unitPrice - 200.0) < 0.001,
                   "montant total cohérent avec le débit réel (200 €)",
                   "\(o.quantity * o.unitPrice)")
        }
    }

    // MARK: - t2ter — A footer with grouped columns (fees confused with the gross amount)

    @Test("Footer 4 colonnes groupées (Montant brut | Commission | Frais | Montant net)")
    func t2ter() throws {
        // ⚠️ A real bug (user feedback, a real trade confirmation capture — BNPP EASY
        // S&P 500, 5 shares @ €27.9161): the rendered fees were EXACTLY
        // the gross amount (€139.58), doubling the displayed total to €279.16
        // instead of the real debit of €140.28. Cause: `firstNumberNearLabel`, on a
        // line of GROUPED VALUES (the footer's 4 headers on one line, the
        // 4 values on the next), returns the FIRST number on the line — the
        // gross amount, positionally first — as soon as "Commission" isn't the
        // 1st column. A footer with grouped columns, unlike the
        // "label: value" line-by-line format of t2, is common
        // among brokers who export their confirmations as a table.
        let pdf = """
        ACHAT COMPTANT
        ACTION
        Date et heure
        locale d'exécution Quantité Informations sur la valeur Informations sur l'exécution
        08/11/2024 5 BNPP EASY S&P 500 UC.EUR ETF Référence : 010173469017
        17:04:30 Code ISIN : FR0011550185 Type d'ordre : au marché
        Cours exécuté : 27,9161 EUR
        Lieu d'exécution : EURONEXT PARIS
        Montant brut Commission Frais (♦) Montant net au débit de votre compte
        139,58 EUR 0,70 EUR 140,28 EUR
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: pdf)
        expect(orders.count == 1, "1 opération extraite", "\(orders.count)")
        if let o = orders.first {
            expect(o.quantity == 5, "quantité correcte", "\(o.quantity)")
            expect(abs(o.unitPrice - 27.9161) < 0.001, "cours correct", "\(o.unitPrice)")
            expect(abs(o.fees - 0.70) < 0.01,
                   "frais réels (0,70 €), pas le montant brut confondu avec eux",
                   "\(o.fees)")
            expect(abs(o.quantity * o.unitPrice + o.fees - 140.28) < 0.01,
                   "total cohérent avec le débit réel (140,28 €), pas le double",
                   "\(o.quantity * o.unitPrice + o.fees)")
        }
    }

    // MARK: - t3 — Vente et formats anglo-saxons

    @Test("Vente, format US (point décimal, virgule de milliers)")
    func t3() throws {
        let text = """
        Trade Confirmation
        APPLE INC
        US0378331005
        SELL
        2024-06-10
        Quantity: 12
        Price: 1,234.56 USD
        Commission: 0.99 USD
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: text)
        expect(orders.count == 1, "1 opération extraite", "\(orders.count)")
        if let o = orders.first {
            expect(o.orderType == "SELL", "vente reconnue", o.orderType)
            expect(abs(o.unitPrice - 1234.56) < 0.001, "1,234.56 lu à l'anglo-saxonne", "\(o.unitPrice)")
            expect(o.currency == "USD", "devise détectée", o.currency)
            expect(o.executedAt == "2024-06-10", "date ISO conservée", o.executedAt)
        }
    }

    // MARK: - t4 — Robustness: nothing to extract must invent nothing

    @Test("Aucune invention sur un document sans opération")
    func t4() throws {
        let cgv = """
        Conditions générales
        Article 1 — Objet du contrat
        Le présent document décrit les conditions applicables.
        Référence interne AB1234567890
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: cgv)
        expect(orders.isEmpty, "aucune opération inventée", "\(orders.count) extraite(s)")

        // An ISIN present but with no operation type or date isn't enough.
        let partial = "EPARGNE ETF\nLU1681043599\nValorisation au 31/12/2024"
        expect(InvestmentStatementExtractor.extractOrders(from: partial).isEmpty,
               "ISIN + date sans nature d'opération → ignoré")
    }

    // MARK: - t5 — ISIN validation (Luhn checksum)

    @Test("Validation ISIN — les références internes sont écartées")
    func t5() throws {
        expect(InvestmentStatementExtractor.isValidISIN("FR0013412020"), "FR0013412020 valide")
        expect(InvestmentStatementExtractor.isValidISIN("LU1834988518"), "LU1834988518 valide")
        expect(InvestmentStatementExtractor.isValidISIN("US0378331005"), "US0378331005 valide")
        expect(!InvestmentStatementExtractor.isValidISIN("FR0013412021"), "clé de contrôle fausse rejetée")
        expect(!InvestmentStatementExtractor.isValidISIN("AB1234567890"), "référence interne rejetée")
        expect(!InvestmentStatementExtractor.isValidISIN("FR001341202"), "longueur invalide rejetée")
    }

    // MARK: - t6 — Number parsing

    @Test("Conventions décimales")
    func t6() throws {
        expect(InvestmentStatementExtractor.parseNumber("34,53") == 34.53, "34,53 → 34.53")
        expect(InvestmentStatementExtractor.parseNumber("1 234,56") == 1234.56, "1 234,56 → 1234.56")
        expect(InvestmentStatementExtractor.parseNumber("1,234.56") == 1234.56, "1,234.56 → 1234.56")
        expect(InvestmentStatementExtractor.parseNumber("1.234,56") == 1234.56, "1.234,56 → 1234.56")
        // FR convention: a lone comma is decimal. "Quantité : 2,000"
        // means 2 shares — reading it as 2000 would create a position a thousand times too large.
        expect(InvestmentStatementExtractor.parseNumber("2,000") == 2, "2,000 → 2 (virgule décimale FR)")
        expect(InvestmentStatementExtractor.parseNumber("1,234,567") == 1234567, "1,234,567 → milliers (2 virgules)")
        expect(InvestmentStatementExtractor.parseNumber("-242,92") == -242.92, "négatif conservé")
    }

    // MARK: - Valuation: an operation is never worth 0 when the amount is written

    @Test("Valorisation d'une opération")
    func valorisationduneopration() throws {
        typealias E = InvestmentStatementExtractor

        // ⚠️ THE bug: a dividend has neither a quantity nor an execution price. Forced
        // into the "quantity × price" mold, it came out at €0 on a real trade confirmation.
        let coupon = E.valuation(orderType: "DIV", quantity: nil, unitPrice: nil, gross: 34.53)
        expect(coupon.quantity * coupon.unitPrice == 34.53,
               "dividende sans quantité ni cours vaut son montant",
               "\(coupon.quantity) × \(coupon.unitPrice)")

        // A known quantity: the price is deduced from it, the product stays exact.
        let perShare = E.valuation(orderType: "DIV", quantity: 100, unitPrice: nil, gross: 34.53)
        expect(abs(perShare.quantity * perShare.unitPrice - 34.53) < 0.0001,
               "coupon réparti sur 100 titres reste 34,53 €",
               "\(perShare.quantity) × \(perShare.unitPrice)")
        expect(perShare.quantity == 100, "la quantité lue est conservée")

        // A purchase whose document doesn't name the quantity: same defect, same
        // fix — the total must not fall to zero.
        let buy = E.valuation(orderType: "BUY", quantity: nil, unitPrice: nil, gross: -972.59)
        expect(buy.quantity * buy.unitPrice == 972.59, "achat sans quantité garde son montant",
               "\(buy.quantity) × \(buy.unitPrice)")

        // The nominal case: nothing is touched.
        let normal = E.valuation(orderType: "BUY", quantity: 2, unitPrice: 485.30, gross: -972.59)
        expect(normal.quantity == 2 && normal.unitPrice == 485.30,
               "quantité et cours lus sont conservés tels quels")
        expect(normal.deduced == false, "aucune déduction signalée")

        // ⚠️ Without an amount, nothing is INVENTED: an operation with no
        // value stays valueless, it doesn't become 1 × 0.
        let empty = E.valuation(orderType: "DIV", quantity: nil, unitPrice: nil, gross: nil)
        expect(empty.quantity == 0 && empty.unitPrice == 0,
               "rien d'exploitable → aucun montant fabriqué")
    }

    // MARK: - t8bis — A REAL BoursoBank trade confirmation (verbatim PDFKit text)

    @Test("Avis d'opéré BoursoBank — texte extrait du PDF réel")
    func t8bis() throws {
        // ⚠️ This text is the EXACT output of `PDFPage.string` on the PDF provided
        // by the user (a PDFKit dump), not a reconstruction. It's the only
        // way to test what the app actually sees: the table's 2D layout
        // is already flattened there, mixed columns included.
        let pdf = """
        OPERATION DE BOURSE
        le 09/06/2025
        000000
        P46983
        MR HELET EDWIN
        4 RUE DU CARRE
        10100 GELANNES
        Références de votre compte titres
        40618 80314 00088441579 Compte PEA
        Résident Français
        VENTE COMPTANT ETR
        ACTION
        Date et heure
        locale d'exécution Quantité Informations sur la valeur 09/06/2025
        12:30:21
        Informations sur l'exécution
        4 ISHS CO.EURO STOX50 UC.ETF EUR Référence : 170145383379
        Type d'ordre : au marché
        Code ISIN : IE0008471009 Cours exécuté : 55,62 EUR
        Lieu d'exécution : EURONEXT AMSTERDAM
        Montant transaction brut Intérêts
        222,48 EUR 0,00 EUR
        000 jours
        Montant transaction
        total brut Courtages Montant transaction net
        222,48 EUR 0,00 EUR 0,00 EUR
        Commission Frais divers Montant total des frais
        1,11 EUR 0,00 EUR 1,11 EUR
        Montant net au crédit de votre compte
        221,37 EUR
        Sous réserve de bonne fin.
        """
        let orders = InvestmentStatementExtractor.extractOrders(from: pdf)
        expect(orders.count == 1, "1 opération extraite", "\(orders.count) trouvée(s)")
        if let order = orders.first {
            expect(order.orderType == "SELL", "vente reconnue", order.orderType)
            expect(order.isin == "IE0008471009", "ISIN correct", order.isin)
            expect(order.executedAt == "2025-06-09", "date correcte", order.executedAt)
            // ⚠️ THE reported symptom: "1 × €55.62" instead of "4 × €55.62".
            // Quantity 4 sits three lines below its column header, so it's
            // unfindable by label — but 222.48 ÷ 55.62 = 4 exactly.
            expect(order.quantity == 4, "quantité déduite du montant ÷ cours",
                   "quantité \(order.quantity)")
            expect(abs(order.unitPrice - 55.62) < 0.001, "cours exécuté lu",
                   "\(order.unitPrice)")
            expect(abs(order.quantity * order.unitPrice - 222.48) < 0.01,
                   "le total vaut le montant brut du relevé",
                   "\(order.quantity) × \(order.unitPrice)")
            expect(abs(order.fees - 1.11) < 0.001, "commission lue", "\(order.fees)")
            // ⚠️ The displayed name was "Order type: at market" — the line
            // closest to the ISIN code, but a field heading, not a title.
            expect(order.assetName == "ISHS CO.EURO STOX50 UC.ETF EUR",
                   "nom du titre isolé de sa ligne de tableau", order.assetName)

            // ⚠️ A REGRESSION NEVER TO REINTRODUCE: this quantity is DERIVED
            // (222.48 ÷ 55.62) but arithmetically VERIFIED — its product
            // reproduces the printed gross amount. It must therefore stay above the
            // re-reading threshold, otherwise a model answering "quantity 1" overwrites
            // an exact value and we're back to the original "×1".
            expect(order.confidence >= StatementReconciler.uncertainConfidence,
                   "une quantité vérifiée n'est pas réécrasable par l'IA",
                   "confiance \(order.confidence)")
            let contradicted = ExtractedStatementOrder(
                orderType: "SELL", assetName: "iShares Core EURO STOXX 50",
                isin: "IE0008471009", quantity: 1, unitPrice: 55.62, fees: 0,
                executedAt: "2025-06-09", currency: "EUR", notes: nil, confidence: 0.9)
            let fused = StatementReconciler.reconcile(ai: [contradicted], deterministic: [order])
            expect(fused.count == 1 && fused[0].quantity == 4,
                   "et elle survit à une lecture IA qui la contredit",
                   "quantité \(fused.first?.quantity ?? -1)")
        }
    }

    // MARK: - t9 — Deterministic × AI merge (StatementReconciler)

    @Test("Fusion des deux lectures d'un même relevé")
    func t9() throws {
        typealias R = StatementReconciler

        func order(_ type: String, _ name: String, _ isin: String, day: String,
                   qty: Double, price: Double, fees: Double = 0,
                   confidence: Double, notes: String? = nil) -> ExtractedStatementOrder {
            ExtractedStatementOrder(orderType: type, assetName: name, isin: isin,
                                    quantity: qty, unitPrice: price, fees: fees,
                                    executedAt: day, currency: "EUR", notes: notes,
                                    confidence: confidence)
        }

        // ─── The reported case: a TABLE statement ───────────────────────────────
        // The "Quantité" label appears only once, in the column
        // header. ISIN anchoring can't read it line by line, so
        // it falls back to "1 × amount" and LOWERS its confidence to signal it.
        let det = order("BUY", "ISHARES CORE MSCI", "IE00B4L5Y983", day: "2025-01-13",
                        qty: 1, price: 982.40, confidence: 0.60,
                        notes: "Extraction automatique (ancrage ISIN)")
        let ai = order("BUY", "iShares Core MSCI World", "IE00B4L5Y983", day: "2025-01-13",
                       qty: 4, price: 245.60, confidence: 0.9)

        let fused = R.reconcile(ai: [ai], deterministic: [det])
        expect(fused.count == 1, "une opération lue deux fois reste UNE opération",
               "\(fused.count) rendue(s)")
        expect(fused[0].quantity == 4, "la quantité de l'IA remplace le « 1 » déduit",
               "quantité \(fused[0].quantity)")
        expect(abs(fused[0].quantity * fused[0].unitPrice - 982.40) < 0.01,
               "le montant total est préservé", "\(fused[0].quantity) × \(fused[0].unitPrice)")
        expect(fused[0].notes?.contains(R.textTag) == true,
               "l'opération porte la trace de la relecture IA", fused[0].notes ?? "nil")

        // ⚠️ A PERFECTLY read operation is never overwritten, even if the
        // model proposes something else: the deterministic pass is right where it
        // actually READ the numbers.
        let sure = order("BUY", "TOTALENERGIES SE", "FR0000120271", day: "2025-02-04",
                         qty: 7, price: 34.53, confidence: 0.85)
        let wrong = order("BUY", "TotalEnergies", "FR0000120271", day: "2025-02-04",
                          qty: 1, price: 241.71, confidence: 0.9)
        let kept = R.reconcile(ai: [wrong], deterministic: [sure])
        expect(kept.count == 1 && kept[0].quantity == 7,
               "une lecture sûre n'est pas réécrite par le modèle", "quantité \(kept[0].quantity)")

        // ⚠️ The read AMOUNT takes priority when the model copies the total into the
        // "unit price" field — without this guard, €982.40 became €3,929.60.
        let totalAsPrice = order("BUY", "iShares", "IE00B4L5Y983", day: "2025-01-13",
                                 qty: 4, price: 982.40, confidence: 0.9)
        let guarded = R.reconcile(ai: [totalAsPrice], deterministic: [det])
        expect(abs(guarded[0].quantity * guarded[0].unitPrice - 982.40) < 0.01,
               "un prix unitaire aberrant est redéduit du montant réellement lu",
               "\(guarded[0].quantity) × \(guarded[0].unitPrice)")

        // ─── The count that was inflating: 34 operations rendered as 36-37 ─────────────
        // An operation seen by the AI WITHOUT an ISIN was added with no
        // duplicate check at all (the old filter tested membership in a
        // set of ISINs, which by construction can't contain the empty
        // string).
        let noISIN = order("BUY", "ISHARES CORE MSCI", "", day: "2025-01-13",
                           qty: 4, price: 245.60, confidence: 0.5)
        let deduped = R.reconcile(ai: [noISIN], deterministic: [det])
        expect(deduped.count == 1, "une ligne sans ISIN ne se rajoute pas en double",
               "\(deduped.count) rendue(s)")

        // …but an operation that ONLY the AI saw must still be added.
        let onlyAI = order("DIV", "THALES", "FR0000121329", day: "2025-05-18",
                           qty: 1, price: 2.95, confidence: 0.8)
        let widened = R.reconcile(ai: [noISIN, onlyAI], deterministic: [det])
        expect(widened.count == 2, "une opération vue par la seule IA est conservée",
               "\(widened.count) rendue(s)")

        // ⚠️ Two REAL operations on the same security the same day remain two
        // operations: matching is one-to-one, and the amount breaks the tie.
        let det1 = order("BUY", "EPARGNE", "LU1681043599", day: "2025-03-02",
                         qty: 1, price: 400, confidence: 0.60)
        let det2 = order("BUY", "EPARGNE", "LU1681043599", day: "2025-03-02",
                         qty: 1, price: 900, confidence: 0.60)
        let ai1 = order("BUY", "Epargne", "LU1681043599", day: "2025-03-02",
                        qty: 2, price: 200, confidence: 0.9)
        let ai2 = order("BUY", "Epargne", "LU1681043599", day: "2025-03-02",
                        qty: 3, price: 300, confidence: 0.9)
        let pair = R.reconcile(ai: [ai2, ai1], deterministic: [det1, det2])
        expect(pair.count == 2, "deux opérations du même titre le même jour restent deux",
               "\(pair.count) rendue(s)")
        expect(pair[0].quantity == 2 && pair[1].quantity == 3,
               "chacune reçoit les nombres de SA lecture (appariement par montant)",
               "\(pair[0].quantity) puis \(pair[1].quantity)")

        // The trace distinguishes VISUAL reading from text reading: without it,
        // nothing says afterward which path corrected the operation.
        let visual = R.reconcile(ai: [ai], deterministic: [det], tag: R.imageTag)
        expect(visual[0].notes?.contains(R.imageTag) == true,
               "la lecture image laisse sa propre trace", visual[0].notes ?? "nil")

        // ─── Deduplicating a single source (overlapping blocks) ──────────
        let repeated = R.dedupe([ai, ai, onlyAI])
        expect(repeated.count == 2, "une opération répétée par le modèle ne compte qu'une fois",
               "\(repeated.count) rendue(s)")
        expect(R.dedupe([det1, det2]).count == 2,
               "mais deux montants différents ne sont pas une répétition")

        // Without a deterministic backbone (a pure image path), the AI passes through as-is,
        // deduplicated.
        let aiOnly = R.reconcile(ai: [ai, ai, onlyAI], deterministic: [])
        expect(aiOnly.count == 2, "sans déterministe, la sortie IA est simplement dédupliquée",
               "\(aiOnly.count) rendue(s)")
    }
}
