import Foundation

// Abbreviations and markers of bank labels.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// This knowledge used to live in the `EnrichmentLLMService.instructions` string
// (a prompt about a hundred lines long). There, it was: untestable, unavailable when
// Apple Intelligence is absent (so on every iOS 18), and probabilistically re-derived
// on every label. Here it's deterministic, shared by the AI path and the no-AI path,
// and covered by `run_query_planner_tests.sh`.

enum AbbreviationTable {

    /// Business-type abbreviation → expanded word, injected into the map
    /// search ("BOULANG MARIE" → "boulangerie marie").
    /// The company registry, on the other hand, gets the name as-is: "BOULANG" may be
    /// part of the actual company name.
    static let merchantTypes: [String: String] = [
        // French
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
        // Vietnamese — VNPAY labels are common
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

    /// Payment processors. The merchant is what FOLLOWS — never the processor.
    static let paymentProcessors: Set<String> = [
        "paypal", "stripe", "sumup", "adyen", "square", "klarna", "revolut",
        "vnpay", "alipay", "wechat", "payu", "mollie", "checkout", "shopify",
        "applepay", "googlepay", "samsungpay", "lydia", "wero", "paylib"
    ]

    /// French bank operation prefixes. Purely structural, never a merchant.
    static let bankPrefixes: Set<String> = [
        "paiement", "cb", "carte", "vir", "virement", "prlv", "prelevement", "prelvt",
        "sepa", "inst", "recu", "emis", "retrait", "dab", "frais", "ech", "echeance",
        "achat", "facture", "fact", "pmt", "pos", "remise", "cheque", "chq", "avoir"
    ]

    /// Markers that END the merchant slot in fixed-field statements.
    /// "… AUCHAN NIMES **CARTE** 1042 GIR0100794…": everything after is structural.
    static let cardTerminators: Set<String> = ["carte", "payweb", "paywebc"]

    /// Reference codes with no identifying value, to strip everywhere.
    static let referenceMarkers: Set<String> = ["psc", "ref", "gir", "gip", "payli", "no", "num"]

    /// Expands known abbreviations in a list of tokens.
    /// Handles multi-word expressions first ("nha hang", "cong ty tnhh"),
    /// then isolated tokens. Without the multi-word pass, "NHA HANG RAU M" would lose
    /// the expression's meaning and "nha" alone means nothing.
    static func expand(_ tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return [] }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            // 3-word then 2-word expressions.
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

    /// "PAYLI2469", "GIR012607803713662", "PAYWEB1042": a known marker
    /// immediately followed by digits.
    static func isReferenceWithDigits(_ token: String) -> Bool {
        for marker in referenceMarkers.union(cardTerminators) where token.hasPrefix(marker) {
            let tail = token.dropFirst(marker.count)
            if !tail.isEmpty && tail.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}
