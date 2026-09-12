import Foundation

// Recognition of fixed-field bank label templates.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// WHY THIS FILE EXISTS
//
// Analysis of 975 real labels showed that 492 of the 538 "PAIEMENT" labels (91%)
// follow a STRICT template:
//
//     PAIEMENT (PSC|CB) DDMM [DEP] <LOCALITY> <MERCHANT> (CARTE|PAYWEB) NNNN [GIR/GIP<id>]
//
// Three consequences that nothing else in the chain knows how to handle:
//
//  1. THE LOCALITY COMES BEFORE THE MERCHANT. But `NemorisEngine.NormalizerPipeline`
//     only tags a city if it's the last or second-to-last token. On this format, it
//     never sees it — so it ends up in `q=` and makes the search fail.
//
//  2. THE LOCALITY FIELD IS TRUNCATED at ~13 characters: "GIF-SUR-YVETT", "PARIS LA DEFE",
//     "CORMEILLES EN", "PERROGNEY LES", "ROSIERES PRES", "ISSY LES". No exact-match
//     dictionary can recognize them. It's `geo.api.gouv.fr` that
//     resolves them (verified: "ISSY LES" → Issy-les-Moulineaux, insee 92040).
//
//  3. THE MERCHANT IS TRUNCATED TOO: "SC-PHIE NIMES V", "APPLE COM/BILL",
//     "SOUNDCLOUD MONTH". Hence `MerchantTokenSimilarity`'s prefix bonus.
//
// A template is pure, testable DATA: adding another bank's format is
// an entry in `all` and a test scenario — never a change to the
// planner.

/// Slots spotted in a label by a template.
struct TemplateSlots: Hashable, Sendable {
    /// Indices of the tokens forming the locality. nil if the template says there
    /// isn't one (a web payment) or if it couldn't locate it.
    let localityRange: Range<Int>?
    /// Indices of the tokens forming the merchant's name.
    let merchantRange: Range<Int>
    /// 2-digit department code, when the label carries it explicitly
    /// ("35 RENNES") — a free, unambiguous filter.
    let departmentCode: String?
    /// A web payment: no physical locality, so no geo filter or
    /// proximity search.
    let isOnlinePayment: Bool
    /// Everything the template discarded, with the reason.
    let dropped: [DroppedToken]
}

struct BankLabelTemplate: Sendable {
    let id: String
    /// Readable name, shown in "Search details".
    let displayName: String
    /// Tries to split `tokens`. Returns nil if the template doesn't apply.
    let slots: @Sendable (_ tokens: [String]) -> TemplateSlots?

    /// Known templates, tried in order. The first one that matches wins.
    static let all: [BankLabelTemplate] = [.cardPaymentFixedField]

    /// First template that recognizes this label.
    static func match(_ tokens: [String]) -> (template: BankLabelTemplate, slots: TemplateSlots)? {
        for template in all {
            if let slots = template.slots(tokens) {
                return (template, slots)
            }
        }
        return nil
    }
}

// MARK: - "Fixed-field card payment" template

extension BankLabelTemplate {

    /// `PAIEMENT (PSC|CB) DDMM [DEP] <LOCALITY> <MERCHANT> (CARTE|PAYWEB) NNNN [GIR/GIP<id>]`
    ///
    /// Observed on Crédit Mutuel / CIC statements. Covers 91% of the "PAIEMENT"
    /// labels in the reference corpus.
    static let cardPaymentFixedField = BankLabelTemplate(
        id: "card_payment_fixed_field",
        displayName: "Paiement carte (champs fixes)"
    ) { tokens in
        // --- Ancrage : PAIEMENT (PSC|CB) DDMM
        guard tokens.count >= 4, tokens[0] == "paiement" else { return nil }
        guard tokens[1] == "psc" || tokens[1] == "cb" else { return nil }
        guard isDayMonth(tokens[2]) else { return nil }

        var dropped: [DroppedToken] = [
            DroppedToken(value: tokens[0], reason: .processorPrefix),
            DroppedToken(value: tokens[1], reason: .processorPrefix),
            DroppedToken(value: tokens[2], reason: .date)
        ]
        var cursor = 3

        // --- Tail: GIR/GIP… transaction identifiers, starting from the end.
        var end = tokens.count
        while end > cursor, isTransactionId(tokens[end - 1]) {
            dropped.append(DroppedToken(value: tokens[end - 1], reason: .transactionId))
            end -= 1
        }

        // --- Terminator: CARTE NNNN  |  PAYWEB NNNN  |  PAYWEB1042 (glued)
        var isOnline = false
        if end > cursor {
            let last = tokens[end - 1]
            if last.allSatisfy(\.isNumber), end - 1 > cursor,
               AbbreviationTable.cardTerminators.contains(tokens[end - 2]) {
                // "CARTE 1042" / "PAYWEB 1042"
                isOnline = tokens[end - 2].hasPrefix("payweb")
                dropped.append(DroppedToken(value: tokens[end - 2], reason: .cardMarker))
                dropped.append(DroppedToken(value: last, reason: .cardMarker))
                end -= 2
            } else if AbbreviationTable.cardTerminators.contains(where: { last.hasPrefix($0) }),
                      AbbreviationTable.isReferenceWithDigits(last) {
                // "PAYWEB1042" glued together
                isOnline = last.hasPrefix("payweb")
                dropped.append(DroppedToken(value: last, reason: .cardMarker))
                end -= 1
            }
        }
        guard end > cursor else { return nil }

        // --- Explicit department: "35 RENNES", "91 GIF-SUR-YV"
        var departmentCode: String? = nil
        if cursor < end, tokens[cursor].count == 2, tokens[cursor].allSatisfy(\.isNumber),
           cursor + 1 < end {
            departmentCode = tokens[cursor]
            dropped.append(DroppedToken(value: tokens[cursor], reason: .departmentCode))
            cursor += 1
        }

        // --- Online payment reference in the locality slot: "PAYLI2469"
        // It's not a city, and its presence signals a web payment (no place).
        if cursor < end, tokens[cursor].hasPrefix("payli") {
            dropped.append(DroppedToken(value: tokens[cursor], reason: .paymentReference))
            cursor += 1
            isOnline = true
        }
        guard cursor < end else { return nil }

        // --- Splitting locality / merchant.
        // A web payment has no locality: everything else is the merchant.
        if isOnline {
            return TemplateSlots(
                localityRange: nil,
                merchantRange: cursor..<end,
                departmentCode: departmentCode,
                isOnlinePayment: true,
                dropped: dropped
            )
        }

        // Otherwise, the locality occupies the HEAD of the slot and the merchant the rest.
        // Hard constraint: at least one token must always remain for the merchant,
        // otherwise we'd get an empty `q=` — the worst possible result.
        let available = end - cursor
        guard available >= 2 else {
            // A single token: that's the merchant, not the city. An empty "q" is useless.
            return TemplateSlots(
                localityRange: nil,
                merchantRange: cursor..<end,
                departmentCode: departmentCode,
                isOnlinePayment: false,
                dropped: dropped
            )
        }
        let localitySpan = localityTokenCount(tokens, from: cursor, limit: available - 1)
        return TemplateSlots(
            localityRange: cursor..<(cursor + localitySpan),
            merchantRange: (cursor + localitySpan)..<end,
            departmentCode: departmentCode,
            isOnlinePayment: false,
            dropped: dropped
        )
    }

    /// How many tokens the locality actually occupies at the head of the slot.
    ///
    /// ⚠️ DEFINITELY NOT the maximum available. The vast majority of communes fit
    /// in ONE word (LYON, NIMES, OULLINS, ROUBAIX, CORK, BERLIN); greedily taking
    /// three tokens turned "AMSTERDAM DOTT SCOOTER RID" into the locality
    /// "amsterdam dott scooter" and the merchant "rid" — the merchant was eaten by the
    /// city.
    ///
    /// So we grow from 1, and only on an EXPLICIT signal:
    ///   • a toponymic particle  → "GIF **SUR** YVETT", "ISSY **LES**",
    ///     "CORMEILLES **EN**", "ROSIERES **PRES**", "PARIS **LA** DEFE"
    ///   • an arrondissement number → "PARIS **6**"
    /// With no signal, the locality is a single word.
    static func localityTokenCount(_ tokens: [String], from start: Int, limit: Int) -> Int {
        guard limit >= 1 else { return 0 }
        var span = 1
        while span < min(limit, maxLocalityTokens) {
            let next = tokens[start + span]
            if toponymParticles.contains(next) {
                // A particle calls for the word that follows it ("sur" + "yvett").
                span += 1
                if span < min(limit, maxLocalityTokens) { span += 1 }
                continue
            }
            // Arrondissement: "PARIS 6", "MARSEILLE 2".
            if span == 1, next.count <= 2, next.allSatisfy(\.isNumber) {
                span += 1
                continue
            }
            break
        }
        return min(span, limit)
    }

    /// The locality field on statements is ~13 characters, which caps it in
    /// practice at 3 words ("MONT SUR LOIR", "PARIS LA DEFE", "CORMEILLES EN").
    private static let maxLocalityTokens = 3

    /// Particles that extend a French commune name.
    static let toponymParticles: Set<String> = [
        "sur", "sous", "en", "les", "le", "la", "lez", "de", "du", "des", "aux", "au",
        "pres", "saint", "st", "sainte", "ste", "mont", "val", "sr", "d", "l"
    ]

    /// "1803" = March 18th. Four digits forming a valid day and month.
    static func isDayMonth(_ token: String) -> Bool {
        guard token.count == 4, token.allSatisfy(\.isNumber) else { return false }
        guard let day = Int(token.prefix(2)), let month = Int(token.suffix(2)) else { return false }
        return (1...31).contains(day) && (1...12).contains(month)
    }

    /// "GIR012607803713662", "GIP010079487221556", "CG3W26063M200769".
    static func isTransactionId(_ token: String) -> Bool {
        if AbbreviationTable.isReferenceWithDigits(token),
           token.hasPrefix("gir") || token.hasPrefix("gip") { return true }
        // A long string mixing letters and digits, with no usable vowel.
        guard token.count >= 10 else { return false }
        let hasDigit = token.contains(where: \.isNumber)
        let hasLetter = token.contains(where: \.isLetter)
        let digitCount = token.filter(\.isNumber).count
        return hasDigit && hasLetter && digitCount >= token.count / 2
    }
}
