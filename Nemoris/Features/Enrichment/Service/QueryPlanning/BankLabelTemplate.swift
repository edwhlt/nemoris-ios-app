import Foundation

// Reconnaissance des gabarits de libellés bancaires à champs fixes.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// POURQUOI CE FICHIER EXISTE
//
// L'analyse de 975 libellés réels a montré que 492 des 538 libellés « PAIEMENT » (91 %)
// suivent un gabarit STRICT :
//
//     PAIEMENT (PSC|CB) DDMM [DEP] <LOCALITÉ> <MARCHAND> (CARTE|PAYWEB) NNNN [GIR/GIP<id>]
//
// Trois conséquences que rien d'autre dans la chaîne ne sait traiter :
//
//  1. LA LOCALITÉ EST AVANT LE MARCHAND. Or `NemorisEngine.NormalizerPipeline` ne tague
//     une ville que si elle est le dernier ou l'avant-dernier token. Sur ce format, il ne
//     la voit jamais — elle part donc dans `q=` et fait échouer la recherche.
//
//  2. LE CHAMP LOCALITÉ EST TRONQUÉ à ~13 caractères : « GIF-SUR-YVETT », « PARIS LA DEFE »,
//     « CORMEILLES EN », « PERROGNEY LES », « ROSIERES PRES », « ISSY LES ». Aucun
//     dictionnaire en correspondance exacte ne peut les reconnaître. C'est `geo.api.gouv.fr`
//     qui les résout (vérifié : « ISSY LES » → Issy-les-Moulineaux, insee 92040).
//
//  3. LE MARCHAND EST TRONQUÉ AUSSI : « SC-PHIE MASSY V », « APPLE COM/BILL »,
//     « SOUNDCLOUD MONTH ». D'où le bonus de préfixe de `MerchantTokenSimilarity`.
//
// Un gabarit est une DONNÉE pure et testable : ajouter le format d'une autre banque,
// c'est une entrée dans `all` et un scénario de test — jamais une modification du
// planificateur.

/// Créneaux repérés dans un libellé par un gabarit.
struct TemplateSlots: Hashable, Sendable {
    /// Indices des tokens formant la localité. nil si le gabarit dit qu'il n'y en a pas
    /// (paiement web) ou s'il n'a pas su la situer.
    let localityRange: Range<Int>?
    /// Indices des tokens formant le nom du marchand.
    let merchantRange: Range<Int>
    /// Code département à 2 chiffres, quand le libellé le porte explicitement
    /// (« 78 VERSAILLES ») — filtre gratuit et non ambigu.
    let departmentCode: String?
    /// Paiement web : pas de localité physique, donc pas de filtre géo ni de recherche
    /// par proximité.
    let isOnlinePayment: Bool
    /// Tout ce que le gabarit a écarté, avec la raison.
    let dropped: [DroppedToken]
}

struct BankLabelTemplate: Sendable {
    let id: String
    /// Nom lisible, affiché dans « Détails de la recherche ».
    let displayName: String
    /// Tente de découper `tokens`. Renvoie nil si le gabarit ne s'applique pas.
    let slots: @Sendable (_ tokens: [String]) -> TemplateSlots?

    /// Gabarits connus, essayés dans l'ordre. Le premier qui répond gagne.
    static let all: [BankLabelTemplate] = [.cardPaymentFixedField]

    /// Premier gabarit qui reconnaît ce libellé.
    static func match(_ tokens: [String]) -> (template: BankLabelTemplate, slots: TemplateSlots)? {
        for template in all {
            if let slots = template.slots(tokens) {
                return (template, slots)
            }
        }
        return nil
    }
}

// MARK: - Gabarit « paiement carte à champs fixes »

extension BankLabelTemplate {

    /// `PAIEMENT (PSC|CB) DDMM [DEP] <LOCALITÉ> <MARCHAND> (CARTE|PAYWEB) NNNN [GIR/GIP<id>]`
    ///
    /// Observé sur les relevés Crédit Mutuel / CIC. Couvre 91 % des libellés « PAIEMENT »
    /// du corpus de référence.
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

        // --- Queue : identifiants de transaction GIR/GIP…, en partant de la fin.
        var end = tokens.count
        while end > cursor, isTransactionId(tokens[end - 1]) {
            dropped.append(DroppedToken(value: tokens[end - 1], reason: .transactionId))
            end -= 1
        }

        // --- Terminateur : CARTE NNNN  |  PAYWEB NNNN  |  PAYWEB5974 (collé)
        var isOnline = false
        if end > cursor {
            let last = tokens[end - 1]
            if last.allSatisfy(\.isNumber), end - 1 > cursor,
               AbbreviationTable.cardTerminators.contains(tokens[end - 2]) {
                // « CARTE 5974 » / « PAYWEB 5974 »
                isOnline = tokens[end - 2].hasPrefix("payweb")
                dropped.append(DroppedToken(value: tokens[end - 2], reason: .cardMarker))
                dropped.append(DroppedToken(value: last, reason: .cardMarker))
                end -= 2
            } else if AbbreviationTable.cardTerminators.contains(where: { last.hasPrefix($0) }),
                      AbbreviationTable.isReferenceWithDigits(last) {
                // « PAYWEB5974 » collé
                isOnline = last.hasPrefix("payweb")
                dropped.append(DroppedToken(value: last, reason: .cardMarker))
                end -= 1
            }
        }
        guard end > cursor else { return nil }

        // --- Département explicite : « 78 VERSAILLES », « 91 GIF-SUR-YV »
        var departmentCode: String? = nil
        if cursor < end, tokens[cursor].count == 2, tokens[cursor].allSatisfy(\.isNumber),
           cursor + 1 < end {
            departmentCode = tokens[cursor]
            dropped.append(DroppedToken(value: tokens[cursor], reason: .departmentCode))
            cursor += 1
        }

        // --- Référence de paiement en ligne dans le créneau localité : « PAYLI2469 »
        // Ce n'est pas une ville, et sa présence signe un paiement web (pas de lieu).
        if cursor < end, tokens[cursor].hasPrefix("payli") {
            dropped.append(DroppedToken(value: tokens[cursor], reason: .paymentReference))
            cursor += 1
            isOnline = true
        }
        guard cursor < end else { return nil }

        // --- Découpe localité / marchand.
        // Un paiement web n'a pas de localité : tout le reste est le marchand.
        if isOnline {
            return TemplateSlots(
                localityRange: nil,
                merchantRange: cursor..<end,
                departmentCode: departmentCode,
                isOnlinePayment: true,
                dropped: dropped
            )
        }

        // Sinon, la localité occupe la TÊTE du créneau et le marchand la suite.
        // Contrainte dure : il doit TOUJOURS rester au moins un token pour le marchand,
        // sinon on aurait un `q=` vide — le pire résultat possible.
        let available = end - cursor
        guard available >= 2 else {
            // Un seul token : c'est le marchand, pas la ville. « q » vide ne sert à rien.
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

    /// Combien de tokens la localité occupe réellement en tête du créneau.
    ///
    /// ⚠️ Surtout PAS le maximum disponible. La très grande majorité des communes tiennent
    /// en UN mot (LYON, MASSY, OULLINS, ROUBAIX, CORK, BERLIN) ; prendre gloutonnement
    /// trois tokens transformait « AMSTERDAM DOTT SCOOTER RID » en localité
    /// « amsterdam dott scooter » et marchand « rid » — le marchand était mangé par la ville.
    ///
    /// On étend donc à partir de 1, et uniquement sur un signal EXPLICITE :
    ///   • une particule toponymique  → « GIF **SUR** YVETT », « ISSY **LES** »,
    ///     « CORMEILLES **EN** », « ROSIERES **PRES** », « PARIS **LA** DEFE »
    ///   • un numéro d'arrondissement → « PARIS **6** »
    /// Sans signal, la localité fait un seul mot.
    static func localityTokenCount(_ tokens: [String], from start: Int, limit: Int) -> Int {
        guard limit >= 1 else { return 0 }
        var span = 1
        while span < min(limit, maxLocalityTokens) {
            let next = tokens[start + span]
            if toponymParticles.contains(next) {
                // Une particule appelle le mot qui la suit (« sur » + « yvett »).
                span += 1
                if span < min(limit, maxLocalityTokens) { span += 1 }
                continue
            }
            // Arrondissement : « PARIS 6 », « MARSEILLE 2 ».
            if span == 1, next.count <= 2, next.allSatisfy(\.isNumber) {
                span += 1
                continue
            }
            break
        }
        return min(span, limit)
    }

    /// Le champ localité des relevés fait ~13 caractères, ce qui plafonne en pratique
    /// à 3 mots (« GIF SUR YVETT », « PARIS LA DEFE », « CORMEILLES EN »).
    private static let maxLocalityTokens = 3

    /// Particules qui prolongent un nom de commune français.
    static let toponymParticles: Set<String> = [
        "sur", "sous", "en", "les", "le", "la", "lez", "de", "du", "des", "aux", "au",
        "pres", "saint", "st", "sainte", "ste", "mont", "val", "sr", "d", "l"
    ]

    /// « 1803 » = 18 mars. Quatre chiffres formant un jour et un mois valides.
    static func isDayMonth(_ token: String) -> Bool {
        guard token.count == 4, token.allSatisfy(\.isNumber) else { return false }
        guard let day = Int(token.prefix(2)), let month = Int(token.suffix(2)) else { return false }
        return (1...31).contains(day) && (1...12).contains(month)
    }

    /// « GIR012607803713662 », « GIP010079487221556 », « CG3W26063M200769 ».
    static func isTransactionId(_ token: String) -> Bool {
        if AbbreviationTable.isReferenceWithDigits(token),
           token.hasPrefix("gir") || token.hasPrefix("gip") { return true }
        // Chaîne longue mélangeant lettres et chiffres, sans voyelle exploitable.
        guard token.count >= 10 else { return false }
        let hasDigit = token.contains(where: \.isNumber)
        let hasLetter = token.contains(where: \.isLetter)
        let digitCount = token.filter(\.isNumber).count
        return hasDigit && hasLetter && digitCount >= token.count / 2
    }
}
