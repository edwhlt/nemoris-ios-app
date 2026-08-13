import Foundation
import Testing

@testable import Nemoris

/// Extraction déterministe des opérations d'un relevé d'investissement.
///
/// L'ancrage se fait sur l'ISIN, validé par sa clé de contrôle — ce qui
/// écarte les références internes de banque. Deux fenêtres distinctes par
/// opération : les champs se lisent APRÈS l'ancre, le nom AVANT. Une fenêtre
/// unique faisait hériter au bloc N les champs du bloc précédent.
@Suite("Extraction d'avis d'opéré")
struct InvestmentStatementExtractorEngineTests {

    // Ces aides propagent la localisation de l'appelant : sans elle,
    // tout échec pointerait ici au lieu du test concerné.
    private func expect(_ condition: Bool, _ label: String, _ detail: String = "",
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label)\(detail.isEmpty ? "" : " — \(detail)")",
                sourceLocation: sourceLocation)
    }


    // Harness sans XCTest — compile le fichier RÉEL du moteur (cf. run_statement_extractor_tests.sh).
    // À lancer après toute modification de `InvestmentStatementExtractor`.




    // MARK: - t1 — Capture d'écran d'app (le cas qui échouait en production)

    @Test("Capture Boursorama « Mes mouvements » (OCR en colonne)")
    func t1() throws {
        // Texte OCR réel : un champ par ligne, ordre nom → ISIN → opération → date.
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
        // Le piège du bloc suivant : sans borne de ligne sur les libellés, la
        // quantité de l'opération suivante était happée.
        if orders.count > 1 {
            expect(orders[1].quantity == 2, "quantité du 2e bloc non contaminée par le 1er", "\(orders[1].quantity)")
            expect(abs(orders[1].unitPrice - 112.76) < 0.001, "cours du 2e bloc", "\(orders[1].unitPrice)")
        }
        let coupons = orders.filter { $0.orderType == "DIV" }
        expect(coupons.count == 2, "les 2 coupons sont typés DIV", "\(coupons.count)")
        // Coupon sans cours affiché → prix unitaire déduit du montant / quantité.
        if let tte = orders.first(where: { $0.isin == "FR0000120271" }) {
            expect(abs(tte.unitPrice - 0.85) < 0.01, "cours du coupon déduit (1,70 / 2)", "\(tte.unitPrice)")
        }
    }

    // MARK: - t2 — Avis d'opéré PDF (format tabulaire, une opération par page)

    @Test("Avis d'opéré Boursorama (PDF, libellés explicites)")
    func t2() throws {
        let pdf = """
        BOURSORAMA BANQUE
        Avis d'opéré
        AMUNDI MSCI WORLD UCITS ETF - EUR (C)
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
            expect(o.assetName.contains("AMUNDI"), "nom du titre", o.assetName)
        }
    }

    // MARK: - t2bis — Vrai TABLEAU : la quantité arrive AVANT l'ISIN

    @Test("Avis d'opéré en tableau (quantité alignée avec la date, avant l'ISIN)")
    func t2bis() throws {
        // ⚠️ Reproduction du texte tel que PDFKit l'aplatit pour un VRAI tableau
        // (pas un format « libellé : valeur » ligne par ligne comme t2). Le nom du
        // titre et l'ISIN occupent DEUX sous-lignes de leur cellule, alors que la
        // quantité — dans la cellule voisine, alignée avec la première sous-ligne
        // (la date) — se retrouve donc AVANT l'ISIN dans le texte linéaire, avec
        // d'autres lignes de document entre les deux. Bug réel : sans repli sur la
        // fenêtre d'AVANT pour les champs numériques (pas seulement la date), la
        // quantité restait introuvable — remplacée par 1, ce qui faussait aussi le
        // montant total (50 € au lieu de 200 €).
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

    // MARK: - t2ter — Footer à colonnes groupées (frais confondus avec le brut)

    @Test("Footer 4 colonnes groupées (Montant brut | Commission | Frais | Montant net)")
    func t2ter() throws {
        // ⚠️ Bug réel (retour user, capture d'un avis d'opéré réel — BNPP EASY
        // S&P 500, 5 titres @ 27,9161 €) : les frais rendus valaient EXACTEMENT
        // le montant brut (139,58 €), doublant le total affiché à 279,16 € au
        // lieu du débit réel 140,28 €. Cause : `firstNumberNearLabel`, sur une
        // ligne de VALEURS groupées (les 4 en-têtes du footer sur une ligne, les
        // 4 valeurs sur la suivante), rend le PREMIER nombre de la ligne — le
        // montant brut, positionnellement en tête — dès que « Commission » n'est
        // pas la 1ʳᵉ colonne. Un footer à colonnes groupées, contrairement au
        // format « libellé : valeur » ligne par ligne de t2, est monnaie
        // courante chez les courtiers qui exportent leurs avis en tableau.
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

    // MARK: - t4 — Robustesse : rien à extraire ne doit rien inventer

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

        // Un ISIN présent mais sans nature d'opération ni date ne suffit pas.
        let partial = "AMUNDI ETF\nLU1681043599\nValorisation au 31/12/2024"
        expect(InvestmentStatementExtractor.extractOrders(from: partial).isEmpty,
               "ISIN + date sans nature d'opération → ignoré")
    }

    // MARK: - t5 — Validation ISIN (clé de Luhn)

    @Test("Validation ISIN — les références internes sont écartées")
    func t5() throws {
        expect(InvestmentStatementExtractor.isValidISIN("FR0013412020"), "FR0013412020 valide")
        expect(InvestmentStatementExtractor.isValidISIN("LU1834988518"), "LU1834988518 valide")
        expect(InvestmentStatementExtractor.isValidISIN("US0378331005"), "US0378331005 valide")
        expect(!InvestmentStatementExtractor.isValidISIN("FR0013412021"), "clé de contrôle fausse rejetée")
        expect(!InvestmentStatementExtractor.isValidISIN("AB1234567890"), "référence interne rejetée")
        expect(!InvestmentStatementExtractor.isValidISIN("FR001341202"), "longueur invalide rejetée")
    }

    // MARK: - t6 — Parsing des nombres

    @Test("Conventions décimales")
    func t6() throws {
        expect(InvestmentStatementExtractor.parseNumber("34,53") == 34.53, "34,53 → 34.53")
        expect(InvestmentStatementExtractor.parseNumber("1 234,56") == 1234.56, "1 234,56 → 1234.56")
        expect(InvestmentStatementExtractor.parseNumber("1,234.56") == 1234.56, "1,234.56 → 1234.56")
        expect(InvestmentStatementExtractor.parseNumber("1.234,56") == 1234.56, "1.234,56 → 1234.56")
        // Convention FR : une virgule seule est décimale. « Quantité : 2,000 »
        // vaut 2 titres — le lire 2000 créerait une position mille fois trop grosse.
        expect(InvestmentStatementExtractor.parseNumber("2,000") == 2, "2,000 → 2 (virgule décimale FR)")
        expect(InvestmentStatementExtractor.parseNumber("1,234,567") == 1234567, "1,234,567 → milliers (2 virgules)")
        expect(InvestmentStatementExtractor.parseNumber("-242,92") == -242.92, "négatif conservé")
    }

    // MARK: - Valorisation : une opération ne vaut jamais 0 quand le montant est écrit

    @Test("Valorisation d'une opération")
    func valorisationduneopration() throws {
        typealias E = InvestmentStatementExtractor

        // ⚠️ LE bug : un dividende n'a ni quantité ni cours d'exécution. Forcé dans
        // le moule « quantité × prix », il ressortait à 0 € sur un avis d'opéré réel.
        let coupon = E.valuation(orderType: "DIV", quantity: nil, unitPrice: nil, gross: 34.53)
        expect(coupon.quantity * coupon.unitPrice == 34.53,
               "dividende sans quantité ni cours vaut son montant",
               "\(coupon.quantity) × \(coupon.unitPrice)")

        // Quantité connue : le prix s'en déduit, le produit reste exact.
        let perShare = E.valuation(orderType: "DIV", quantity: 100, unitPrice: nil, gross: 34.53)
        expect(abs(perShare.quantity * perShare.unitPrice - 34.53) < 0.0001,
               "coupon réparti sur 100 titres reste 34,53 €",
               "\(perShare.quantity) × \(perShare.unitPrice)")
        expect(perShare.quantity == 100, "la quantité lue est conservée")

        // Achat dont le document ne nomme pas la quantité : même défaut, même
        // correction — le total ne doit pas tomber à zéro.
        let buy = E.valuation(orderType: "BUY", quantity: nil, unitPrice: nil, gross: -972.59)
        expect(buy.quantity * buy.unitPrice == 972.59, "achat sans quantité garde son montant",
               "\(buy.quantity) × \(buy.unitPrice)")

        // Cas nominal : rien n'est touché.
        let normal = E.valuation(orderType: "BUY", quantity: 2, unitPrice: 485.30, gross: -972.59)
        expect(normal.quantity == 2 && normal.unitPrice == 485.30,
               "quantité et cours lus sont conservés tels quels")
        expect(normal.deduced == false, "aucune déduction signalée")

        // ⚠️ Sans montant, on n'INVENTE pas : une opération sans valeur reste sans
        // valeur, elle ne devient pas 1 × 0.
        let empty = E.valuation(orderType: "DIV", quantity: nil, unitPrice: nil, gross: nil)
        expect(empty.quantity == 0 && empty.unitPrice == 0,
               "rien d'exploitable → aucun montant fabriqué")
    }

    // MARK: - t8bis — Avis d'opéré BoursoBank RÉEL (texte PDFKit vérbatim)

    @Test("Avis d'opéré BoursoBank — texte extrait du PDF réel")
    func t8bis() throws {
        // ⚠️ Ce texte est la sortie EXACTE de `PDFPage.string` sur le PDF fourni
        // par l'utilisateur (dump PDFKit), pas une reconstruction. C'est la seule
        // façon de tester ce que l'app voit réellement : la mise en page 2D du
        // tableau y est déjà aplatie, colonnes mélangées comprises.
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
            // ⚠️ LE symptôme rapporté : « 1 × 55,62 € » au lieu de « 4 × 55,62 € ».
            // La quantité 4 est trois lignes sous son en-tête de colonne, donc
            // introuvable par libellé — mais 222,48 ÷ 55,62 = 4 exactement.
            expect(order.quantity == 4, "quantité déduite du montant ÷ cours",
                   "quantité \(order.quantity)")
            expect(abs(order.unitPrice - 55.62) < 0.001, "cours exécuté lu",
                   "\(order.unitPrice)")
            expect(abs(order.quantity * order.unitPrice - 222.48) < 0.01,
                   "le total vaut le montant brut du relevé",
                   "\(order.quantity) × \(order.unitPrice)")
            expect(abs(order.fees - 1.11) < 0.001, "commission lue", "\(order.fees)")
            // ⚠️ Le nom affiché était « Type d'ordre : au marché » — la ligne la
            // plus proche du code ISIN, mais un intitulé de champ, pas un titre.
            expect(order.assetName == "ISHS CO.EURO STOX50 UC.ETF EUR",
                   "nom du titre isolé de sa ligne de tableau", order.assetName)

            // ⚠️ RÉGRESSION À NE JAMAIS REPERDRE : cette quantité est DÉRIVÉE
            // (222,48 ÷ 55,62) mais arithmétiquement VÉRIFIÉE — son produit
            // reproduit le montant brut imprimé. Elle doit donc rester au-dessus du
            // seuil de relecture, sinon un modèle qui répond « quantité 1 » écrase
            // une valeur exacte et on retombe sur le « ×1 » d'origine.
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

    // MARK: - t9 — Fusion déterministe × IA (StatementReconciler)

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

        // ─── Le cas signalé : un relevé en TABLEAU ───────────────────────────────
        // Le libellé « Quantité » n'apparaît qu'une fois, dans l'en-tête de
        // colonne. L'ancrage par ISIN ne peut donc pas le lire ligne par ligne :
        // il retombe sur « 1 × montant » et ABAISSE sa confiance pour le dire.
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

        // ⚠️ Une opération PARFAITEMENT lue n'est jamais réécrite, même si le
        // modèle propose autre chose : c'est le déterministe qui a raison là où il
        // a réellement LU les nombres.
        let sure = order("BUY", "TOTALENERGIES SE", "FR0000120271", day: "2025-02-04",
                         qty: 7, price: 34.53, confidence: 0.85)
        let wrong = order("BUY", "TotalEnergies", "FR0000120271", day: "2025-02-04",
                          qty: 1, price: 241.71, confidence: 0.9)
        let kept = R.reconcile(ai: [wrong], deterministic: [sure])
        expect(kept.count == 1 && kept[0].quantity == 7,
               "une lecture sûre n'est pas réécrite par le modèle", "quantité \(kept[0].quantity)")

        // ⚠️ Le MONTANT lu prime quand le modèle recopie le total dans le champ
        // « prix unitaire » — sans ce garde-fou, 982,40 € devenait 3 929,60 €.
        let totalAsPrice = order("BUY", "iShares", "IE00B4L5Y983", day: "2025-01-13",
                                 qty: 4, price: 982.40, confidence: 0.9)
        let guarded = R.reconcile(ai: [totalAsPrice], deterministic: [det])
        expect(abs(guarded[0].quantity * guarded[0].unitPrice - 982.40) < 0.01,
               "un prix unitaire aberrant est redéduit du montant réellement lu",
               "\(guarded[0].quantity) × \(guarded[0].unitPrice)")

        // ─── Le compte qui gonflait : 34 opérations rendues en 36-37 ─────────────
        // Une opération vue par l'IA SANS ISIN était ajoutée sans aucune
        // vérification de doublon (l'ancien filtre testait l'appartenance à un
        // ensemble d'ISIN, qui ne peut par construction pas contenir la chaîne
        // vide).
        let noISIN = order("BUY", "ISHARES CORE MSCI", "", day: "2025-01-13",
                           qty: 4, price: 245.60, confidence: 0.5)
        let deduped = R.reconcile(ai: [noISIN], deterministic: [det])
        expect(deduped.count == 1, "une ligne sans ISIN ne se rajoute pas en double",
               "\(deduped.count) rendue(s)")

        // …mais une opération que SEULE l'IA a vue doit bien être ajoutée.
        let onlyAI = order("DIV", "THALES", "FR0000121329", day: "2025-05-18",
                           qty: 1, price: 2.95, confidence: 0.8)
        let widened = R.reconcile(ai: [noISIN, onlyAI], deterministic: [det])
        expect(widened.count == 2, "une opération vue par la seule IA est conservée",
               "\(widened.count) rendue(s)")

        // ⚠️ Deux opérations RÉELLES du même titre le même jour restent deux
        // opérations : l'appariement est un-pour-un, et le montant départage.
        let det1 = order("BUY", "AMUNDI", "LU1681043599", day: "2025-03-02",
                         qty: 1, price: 400, confidence: 0.60)
        let det2 = order("BUY", "AMUNDI", "LU1681043599", day: "2025-03-02",
                         qty: 1, price: 900, confidence: 0.60)
        let ai1 = order("BUY", "Amundi", "LU1681043599", day: "2025-03-02",
                        qty: 2, price: 200, confidence: 0.9)
        let ai2 = order("BUY", "Amundi", "LU1681043599", day: "2025-03-02",
                        qty: 3, price: 300, confidence: 0.9)
        let pair = R.reconcile(ai: [ai2, ai1], deterministic: [det1, det2])
        expect(pair.count == 2, "deux opérations du même titre le même jour restent deux",
               "\(pair.count) rendue(s)")
        expect(pair[0].quantity == 2 && pair[1].quantity == 3,
               "chacune reçoit les nombres de SA lecture (appariement par montant)",
               "\(pair[0].quantity) puis \(pair[1].quantity)")

        // La trace distingue la lecture VISUELLE de la lecture texte : sans elle,
        // rien ne dit après coup par quel chemin l'opération a été corrigée.
        let visual = R.reconcile(ai: [ai], deterministic: [det], tag: R.imageTag)
        expect(visual[0].notes?.contains(R.imageTag) == true,
               "la lecture image laisse sa propre trace", visual[0].notes ?? "nil")

        // ─── Déduplication d'une source seule (blocs qui se recouvrent) ──────────
        let repeated = R.dedupe([ai, ai, onlyAI])
        expect(repeated.count == 2, "une opération répétée par le modèle ne compte qu'une fois",
               "\(repeated.count) rendue(s)")
        expect(R.dedupe([det1, det2]).count == 2,
               "mais deux montants différents ne sont pas une répétition")

        // Sans ossature déterministe (chemin image pur), l'IA passe telle quelle,
        // dédupliquée.
        let aiOnly = R.reconcile(ai: [ai, ai, onlyAI], deterministic: [])
        expect(aiOnly.count == 2, "sans déterministe, la sortie IA est simplement dédupliquée",
               "\(aiOnly.count) rendue(s)")
    }
}
