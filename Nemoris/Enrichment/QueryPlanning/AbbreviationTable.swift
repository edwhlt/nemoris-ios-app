import Foundation

// AXE S — Abréviations et marqueurs des libellés bancaires.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Ce savoir vivait jusqu'ici dans la chaîne de caractères `EnrichmentLLMService.instructions`
// (un prompt d'une centaine de lignes). Il y était : non testable, indisponible quand
// Apple Intelligence est absent (donc sur tout iOS 18), et re-dérivé probabilistiquement
// à chaque libellé. Ici il est déterministe, partagé par le chemin IA et le chemin sans IA,
// et couvert par `run_query_planner_tests.sh`.

enum AbbreviationTable {

    /// Abréviations de type de commerce → mot développé, injecté dans la requête
    /// cartographique (« BOULANG MARIE » → « boulangerie marie »).
    /// Le registre d'entreprises, lui, reçoit le nom tel quel : « BOULANG » peut faire
    /// partie de la raison sociale.
    static let merchantTypes: [String: String] = [
        // Français
        "res": "restaurant",
        "resto": "restaurant",
        "rest": "restaurant",
        "boulang": "boulangerie",
        "boul": "boulangerie",
        "patiss": "patisserie",
        "pharm": "pharmacie",
        "phie": "pharmacie",
        "hot": "hotel",
        "mkt": "market",
        "sup": "supermarche",
        "stat": "station",
        "gar": "garage",
        "coif": "coiffeur",
        "tab": "tabac",
        "libr": "librairie",
        // Vietnamien — libellés VNPAY fréquents
        "nha hang": "restaurant",
        "nh": "restaurant",
        "quan": "restaurant",
        "cho": "marche",
        "khach san": "hotel",
        "sieu thi": "supermarche",
        "cong ty tnhh": "societe",
        "ho kinh doanh": "commerce familial",
        "acv": "aeroport"
    ]

    /// Processeurs de paiement. Le marchand est ce qui SUIT — jamais le processeur.
    static let paymentProcessors: Set<String> = [
        "paypal", "stripe", "sumup", "adyen", "square", "klarna", "revolut",
        "vnpay", "alipay", "wechat", "payu", "mollie", "checkout", "shopify",
        "applepay", "googlepay", "samsungpay", "lydia", "wero", "paylib"
    ]

    /// Préfixes d'opération bancaire française. Purement structurels, jamais un marchand.
    static let bankPrefixes: Set<String> = [
        "paiement", "cb", "carte", "vir", "virement", "prlv", "prelevement", "prelvt",
        "sepa", "inst", "recu", "emis", "retrait", "dab", "frais", "ech", "echeance",
        "achat", "facture", "fact", "pmt", "pos", "remise", "cheque", "chq", "avoir"
    ]

    /// Marqueurs qui TERMINENT le créneau marchand dans les relevés à champs fixes.
    /// « … AUCHAN MASSY **CARTE** 5974 GIR0100794… » : tout ce qui suit est structurel.
    static let cardTerminators: Set<String> = ["carte", "payweb", "paywebc"]

    /// Codes de référence sans valeur d'identification, à retirer partout.
    static let referenceMarkers: Set<String> = ["psc", "ref", "gir", "gip", "payli", "no", "num"]

    /// Développe les abréviations connues d'une liste de tokens.
    /// Traite d'abord les expressions multi-mots (« nha hang », « cong ty tnhh »),
    /// puis les tokens isolés. Sans le passage multi-mots, « NHA HANG RAU M » perdrait
    /// le sens de l'expression et « nha » seul ne veut rien dire.
    static func expand(_ tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return [] }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            // Expressions de 3 puis 2 mots.
            for span in stride(from: min(3, tokens.count - i), through: 2, by: -1) {
                let phrase = tokens[i..<(i + span)].joined(separator: " ")
                if let expanded = merchantTypes[phrase] {
                    out.append(expanded)
                    i += span
                    matched = true
                    break
                }
            }
            if matched { continue }
            out.append(merchantTypes[tokens[i]] ?? tokens[i])
            i += 1
        }
        return out
    }

    static func isPaymentProcessor(_ token: String) -> Bool {
        paymentProcessors.contains(token)
    }

    static func isBankPrefix(_ token: String) -> Bool {
        bankPrefixes.contains(token)
    }

    /// « PAYLI2469 », « GIR012607803713662 », « PAYWEB5974 » : un marqueur connu
    /// immédiatement suivi de chiffres.
    static func isReferenceWithDigits(_ token: String) -> Bool {
        for marker in referenceMarkers.union(cardTerminators) where token.hasPrefix(marker) {
            let tail = token.dropFirst(marker.count)
            if !tail.isEmpty && tail.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}
