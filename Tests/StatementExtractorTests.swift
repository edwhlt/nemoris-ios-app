import Foundation

// Harness sans XCTest — compile le fichier RÉEL du moteur (cf. run_statement_extractor_tests.sh).
// À lancer après toute modification de `InvestmentStatementExtractor`.

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
enum StatementExtractorTests {
    static func main() {

// MARK: - t1 — Capture d'écran d'app (le cas qui échouait en production)

print("t1 · Capture Boursorama « Mes mouvements » (OCR en colonne)")
do {
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

print("\nt2 · Avis d'opéré Boursorama (PDF, libellés explicites)")
do {
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

// MARK: - t3 — Vente et formats anglo-saxons

print("\nt3 · Vente, format US (point décimal, virgule de milliers)")
do {
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

print("\nt4 · Aucune invention sur un document sans opération")
do {
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

print("\nt5 · Validation ISIN — les références internes sont écartées")
do {
    expect(InvestmentStatementExtractor.isValidISIN("FR0013412020"), "FR0013412020 valide")
    expect(InvestmentStatementExtractor.isValidISIN("LU1834988518"), "LU1834988518 valide")
    expect(InvestmentStatementExtractor.isValidISIN("US0378331005"), "US0378331005 valide")
    expect(!InvestmentStatementExtractor.isValidISIN("FR0013412021"), "clé de contrôle fausse rejetée")
    expect(!InvestmentStatementExtractor.isValidISIN("AB1234567890"), "référence interne rejetée")
    expect(!InvestmentStatementExtractor.isValidISIN("FR001341202"), "longueur invalide rejetée")
}

// MARK: - t6 — Parsing des nombres

print("\nt6 · Conventions décimales")
do {
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

// MARK: - Verdict

print("\n\(checks - failures)/\(checks) assertions OK")
if failures > 0 {
    print("❌ \(failures) échec(s)")
    exit(1)
}
print("✅ Tous les tests passent")

    }
}
