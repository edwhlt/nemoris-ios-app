import Foundation

// AXE S — Raffinement SANS IA.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Produit exactement le même `LLMQueryRefinement` que le chemin `@Generable`. C'est ce
// qui garantit qu'iOS 18 (pas de FoundationModels) et iOS 26 empruntent le même chemin de
// planification, et que le corpus de test mesure le vrai chemin de production.
//
// Il ne remplace pas le modèle : il couvre ce qui est décidable par des règles
// (processeur, code pays, ville étrangère connue, virement nominatif, abréviations). Le
// modèle, lui, sait lire une chaîne multilingue tordue — c'est son seul vrai avantage.

enum DeterministicQueryRefiner {

    /// Motifs de virement nominatif vers une personne physique.
    /// « VIR DE M DIDIER HELET », « VIR INST WERO M NATHAN LAURENT », « VIR SEPA RECU M DUPONT ».
    private static let personTitles: Set<String> = [
        "m", "mr", "mme", "mlle", "mle", "melle", "monsieur", "madame"
    ]

    /// Mots qui, dans un virement, désignent une opération interne et NON une personne
    /// (« VIR LIVRET JEUNE », « VIR AMUNDI ESR ») — ne pas les classer en personne physique.
    /// ⚠️ « remboursement » n'en fait PAS partie : rembourser un ami est le cas le plus
    /// courant de virement entre particuliers (« VIR INST WERO M ADAM FOURNIER
    /// REMBOURSEMENT PHILIPPINES »). L'y mettre annulait la détection sur ces lignes-là.
    private static let nonPersonTransferMarkers: Set<String> = [
        "livret", "compte", "epargne", "pel", "cel", "ldd", "ldds", "pea", "assurance",
        "loyer", "salaire", "caf", "cpam", "urssaf", "impots", "tresor"
    ]

    static func refine(rawLabel: String, tokens: [String]) -> LLMQueryRefinement {
        guard !tokens.isEmpty else { return .none }

        var refinement = LLMQueryRefinement()
        var working = tokens

        // 1) Processeur de paiement.
        if let processor = working.first(where: { AbbreviationTable.isPaymentProcessor($0) }) {
            refinement.processorName = processor
        }

        // 2) Virement nominatif → personne physique.
        refinement.isPersonNotBusiness = detectPerson(tokens: working)

        // 3) Ville étrangère connue → donne AUSSI le pays.
        if let hit = ForeignLocalityTable.findCity(in: working) {
            refinement.localityName = hit.name
            refinement.countryCode = hit.countryCode
            working.removeSubrange(hit.range)
        }

        // 4) Code pays isolé, UNIQUEMENT en position finale ou avant-dernière.
        //    Sans cette contrainte de position, « CB CARREFOUR » verrait « cb » comme un
        //    pays, et « SC-X2M SACLAY » ou « JD PARIS » deviendraient n'importe quoi.
        if refinement.countryCode == nil {
            for index in working.indices.suffix(2) where index >= 0 {
                let token = working[index]
                guard token.count == 2, token.allSatisfy(\.isLetter),
                      ForeignLocalityTable.countryCodes.contains(token) else { continue }
                refinement.countryCode = ForeignLocalityTable.normalizeCountryCode(token)
                break
            }
        }

        // 5) Code postal français : 5 chiffres n'importe où.
        if let pc = working.first(where: { $0.count == 5 && $0.allSatisfy(\.isNumber) }) {
            refinement.postalCode = pc
            if refinement.countryCode == nil { refinement.countryCode = "FR" }
        }

        // 6) Abréviations développées, pour la recherche cartographique.
        let expanded = AbbreviationTable.expand(working)
        if expanded != working {
            refinement.expandedTokens = zip(working, expanded)
                .filter { $0 != $1 }
                .map(\.1)
        }

        // Le raffineur déterministe ne PROPOSE PAS de nom : le découpage nom/localité est
        // le travail du planificateur (gabarit bancaire puis heuristique), qui en sait plus
        // que ces règles. Proposer un `merchantName` ici écraserait un meilleur découpage.
        refinement.confidence = refinement.isEmpty ? 0 : 0.5
        refinement.rationale = "Règles déterministes (sans IA)"
        return refinement
    }

    /// Un virement vers un particulier : titre de civilité suivi d'au moins un mot
    /// alphabétique, dans un libellé de type virement, et sans marqueur d'opération interne.
    private static func detectPerson(tokens: [String]) -> Bool {
        let isTransfer = tokens.contains { $0 == "vir" || $0 == "virement" }
        guard isTransfer else { return false }
        guard !tokens.contains(where: { nonPersonTransferMarkers.contains($0) }) else { return false }

        for (index, token) in tokens.enumerated() where personTitles.contains(token) {
            // Un titre en tout dernier ne désigne personne.
            guard index + 1 < tokens.count else { continue }
            // ⚠️ Un sigle épelé lettre par lettre contient des « M » qui ne sont PAS des
            // civilités : « VIR C P A M TROYES » est la CPAM, pas Monsieur Troyes.
            // Le signe distinctif est le token PRÉCÉDENT : une lettre isolée signe
            // l'épellation, un mot signe un vrai titre (« VIR INST WERO **M** ADAM …»).
            if index > 0, tokens[index - 1].count == 1, tokens[index - 1].allSatisfy(\.isLetter) {
                continue
            }
            let next = tokens[index + 1]
            // Le mot suivant doit ressembler à un nom, pas à une initiale ni à un sigle.
            if next.count >= 3, next.allSatisfy(\.isLetter),
               !AbbreviationTable.isBankPrefix(next),
               !AbbreviationTable.isPaymentProcessor(next) {
                return true
            }
        }
        return false
    }
}
