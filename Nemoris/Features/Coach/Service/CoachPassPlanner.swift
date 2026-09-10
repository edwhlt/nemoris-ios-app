import Foundation

// MARK: - CoachPassPlanner — découper le dossier quand le modèle ne peut pas tout lire
//
// Moteur PUR (`import Foundation` uniquement) : aucun accès base, réseau, IA
// ou SwiftUI. Même doctrine que `CoachBriefingBuilder` / `CoachRanker`.
//
// ─── Le problème, posé honnêtement ─────────────────────────────────────────
//
// Une fenêtre de contexte est un MUR, pas une jauge qui se recharge : ce qui
// n'y tient pas n'est pas « oublié progressivement », il n'est jamais lu.
// Apple Intelligence (`LanguageModelSession`) travaille dans ~4 000 tokens,
// entrée ET sortie confondues, sans aucun paramètre pour l'élargir. Avec
// ~700 tokens de consignes et ~1 600 de dossier, il reste ~1 700 tokens pour
// écrire N recommandations argumentées : c'est ce qui faisait échouer chaque
// analyse sur ce backend.
//
// ⚠️ Ce qu'un outil comme LM Studio fait avec « un document de 50 pages »
// n'est PAS de la mémoire longue : il découpe, il sélectionne ce qui est
// pertinent, et il n'envoie que ça au modèle. La mémoire du modèle, elle, ne
// dépasse jamais sa fenêtre. On applique donc le même principe — à ceci près
// qu'on n'a pas besoin de chercher les passages pertinents : notre dossier
// est DÉJÀ un agrégat structuré, ses sections sont les découpes naturelles.
//
// ─── Ce que fait ce planificateur ──────────────────────────────────────────
//
// Il transforme les sections du dossier en N passes qui tiennent chacune dans
// le budget, chaque passe portant :
//   • les CHIFFRES CLÉS (répétés) — sans eux, une passe « marchands » n'a
//     aucune échelle de référence et conseille dans le vide ;
//   • les OBJECTIFS (répétés) — priorité n°1 du coach, jamais sacrifiés ;
//   • une ou plusieurs sections entières.
//
// La fusion des résultats est DÉTERMINISTE (déduplication par `ref` puis
// `CoachRanker`), pas un appel modèle de plus : demander à une IA de trier ce
// qu'une IA vient d'écrire coûterait un aller-retour, serait non reproductible
// et intestable.

enum CoachPassPlanner {

    /// Taille visée d'UNE passe, en caractères, sur une fenêtre étroite.
    ///
    /// ~2 200 caractères ≈ 600 tokens. Avec ~450 tokens de consignes de passe
    /// partielle, l'entrée tient sous 1 100 tokens : il reste largement de
    /// quoi écrire 2 à 4 recommandations argumentées dans une fenêtre de
    /// 4 000. C'est ce rapport-là qui compte, pas la taille absolue.
    static let compactPassCharacters = 2_200

    /// Place minimale garantie aux SECTIONS dans une passe.
    ///
    /// ⚠️ Sans ce plancher, un utilisateur qui écrit une page d'objectifs
    /// (bornés à 1 500 caractères par le dossier) ne laisserait plus de place
    /// à la matière à analyser : la passe partirait avec des objectifs et
    /// presque aucune donnée.
    static let minimumSectionCharacters = 700

    /// Objectifs répétés dans chaque passe : bornés plus court que dans le
    /// dossier complet, puisqu'ils sont payés N fois.
    static let objectivesPerPassCharacters = 600

    /// Découpe le dossier en passes.
    ///
    /// - Parameters:
    ///   - sections: les blocs nommés du dossier, dans l'ordre de lecture.
    ///   - header: les chiffres clés, répétés dans chaque passe.
    ///   - objectivesBlock: le bloc objectifs déjà formaté, ou `nil`.
    ///   - budget: `.generous` ⇒ UNE passe avec tout (comportement historique).
    static func plan(sections: [CoachBriefingSection],
                     header: String,
                     objectivesBlock: String?,
                     budget: CoachContextBudget) -> [CoachAnalysisPass] {
        let usable = sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }

        // Un backend qui encaisse tout le dossier n'a rien à gagner au
        // découpage : plusieurs appels coûteraient plus cher ET priveraient le
        // modèle de la vue d'ensemble, qui est justement ce qui produit les
        // recommandations transversales.
        if budget == .generous {
            var body = ([header] + usable.map(\.body)).joined(separator: "\n\n")
            if let objectivesBlock { body += "\n\n" + objectivesBlock }
            return [CoachAnalysisPass(index: 1, total: 1,
                                      focus: usable.map(\.title).joined(separator: ", "),
                                      body: body)]
        }

        let objectives = objectivesBlock.map { String($0.prefix(objectivesPerPassCharacters)) }
        let fixedCost = header.count + (objectives.map { $0.count + 2 } ?? 0)
        let sectionBudget = max(minimumSectionCharacters, compactPassCharacters - fixedCost)

        // Regroupement glouton : on remplit une passe tant que la section
        // suivante y tient encore. Une section SEULE plus grosse que le budget
        // est tronquée mais garde sa passe — jamais abandonnée, sinon le
        // découpage ferait disparaître de la matière au lieu de l'étaler.
        var groups: [[CoachBriefingSection]] = []
        var current: [CoachBriefingSection] = []
        var currentCount = 0

        for section in usable {
            let separator = current.isEmpty ? 0 : 2   // le "\n\n" de jointure
            if !current.isEmpty, currentCount + separator + section.body.count > sectionBudget {
                groups.append(current)
                current = []
                currentCount = 0
            }
            currentCount += (current.isEmpty ? 0 : 2) + section.body.count
            current.append(section)
        }
        if !current.isEmpty { groups.append(current) }

        let total = groups.count
        return groups.enumerated().map { offset, group in
            var text = group.map(\.body).joined(separator: "\n\n")
            if text.count > sectionBudget {
                text = String(text.prefix(sectionBudget)) + "\n[…section tronquée]"
            }
            var body = header + "\n\n" + text
            if let objectives { body += "\n\n" + objectives }
            return CoachAnalysisPass(index: offset + 1, total: total,
                                     focus: group.map(\.title).joined(separator: ", "),
                                     body: body)
        }
    }
}
