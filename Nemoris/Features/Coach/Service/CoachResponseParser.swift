import Foundation

// MARK: - CoachResponseParser
//
// Moteur PUR : transforme la réponse BRUTE du modèle en recommandations
// exploitables. Aucun appel réseau, aucune base — donc testable sans modèle.
//
// ⚠️ Tolérance volontaire. Ce parseur ne doit JAMAIS jeter l'analyse entière
// à cause d'une ligne mal formée : c'est la classe de bug déjà payée sur
// l'import de documents (une clé manquante faisait perdre la page complète,
// cf. `LenientJSON`). Ici, une recommandation invalide est ignorée, les autres
// passent.

enum CoachResponseParser {

    /// Pourquoi une réponse n'a rien donné. Distinguer ces cas est essentiel :
    /// « le modèle n'a rien à recommander » est un SUCCÈS, « je n'ai pas su
    /// lire sa réponse » est un DÉFAUT — et les présenter pareil empêche de
    /// diagnostiquer quoi que ce soit.
    enum Failure: Equatable {
        /// Rien d'exploitable : ni JSON valide, ni objet récupérable.
        case unreadable
        /// JSON lu, mais la liste de recommandations est absente du document.
        case missingList
        /// Le modèle a écrit un préambule (le profil) puis a été COUPÉ avant
        /// la moindre recommandation. Cas distinct : il n'y a rien à récupérer,
        /// et la cause est un budget de sortie épuisé — pas un JSON malformé.
        case truncatedBeforeRecommendations
    }

    struct Result {
        var profileSummary: String?
        var drafts: [CoachRecommendationDraft]
        /// `nil` quand la lecture s'est bien passée — y compris avec zéro
        /// recommandation, qui est une réponse légitime.
        var failure: Failure?
        /// Vrai quand les recommandations ont été récupérées une par une dans
        /// une réponse tronquée, au lieu d'être lues d'un bloc.
        var wasSalvaged: Bool = false
    }

    /// Nombre maximal de recommandations retenues par analyse.
    ///
    /// Ce n'est PAS le plafond produit demandé (« on ne se limite pas à 3
    /// suggestions ») : c'est un garde-fou contre un modèle qui partirait en
    /// boucle et rendrait 200 lignes. Au-delà de 40, ce n'est plus un conseil,
    /// c'est du bruit — et ça remplirait la base.
    static let maxRecommendations = 40

    /// Noms acceptés pour la liste de recommandations.
    ///
    /// ⚠️ `recommandations` (orthographe française) n'est PAS une coquetterie :
    /// on demande au modèle de répondre en français, et un modèle qui rédige
    /// en français traduit volontiers ses propres clés JSON. Refuser cette
    /// variante rendait la réponse entière inexploitable.
    private static let listKeys = ["recommendations", "recommandations", "items", "suggestions"]
    private static let profileKeys = ["profile", "profil", "summary", "resume"]

    static func parse(_ raw: String) -> Result {
        let cleaned = LenientJSON.repairSyntax(LenientJSON.repaired(LenientJSON.extractObject(from: raw)))

        // ── Chemin nominal : le document entier est du JSON valide ──────────
        if let data = cleaned.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let profile = profileKeys.compactMap { root[$0] as? String }.first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawItems = listKeys.compactMap({ root[$0] as? [[String: Any]] }).first else {
                return Result(profileSummary: profile?.isEmpty == false ? profile : nil,
                              drafts: [], failure: .missingList)
            }
            // Liste présente mais vide = le modèle n'a rien à proposer. C'est
            // une réponse valide, surtout pas une erreur.
            return Result(profileSummary: profile?.isEmpty == false ? profile : nil,
                          drafts: collect(rawItems), failure: nil)
        }

        // ── Repli : document STRUCTURELLEMENT cassé ─────────────────────────
        //
        // Deux causes vues en production, souvent ensemble :
        //  • réponse COUPÉE en plein JSON (contexte trop court) — les objets
        //    écrits avant la coupure restent complets ;
        //  • le modèle OUBLIE `,"recommendations":` et colle le tableau à la
        //    fin de la chaîne `profile`, qu'il ne referme donc jamais. La
        //    parité des guillemets est alors décalée pour TOUT le reste du
        //    document, ce qui met en échec n'importe quel appariement
        //    d'accolades global (`LenientJSON.innermostObjects` compris).
        //
        // D'où une récupération CIBLÉE : on repart de chaque `{` dont la
        // première clé est une clé de recommandation connue. À partir d'une
        // accolade réelle, la parité redevient fiable quel que soit le
        // désordre qui précède.
        // ⚠️ On repart du texte BRUT, pas de `cleaned` : les réparations
        // globales (guillemets recollés, clés nues citées) supposent de savoir
        // à tout instant si l'on est DANS une chaîne. Sur un document dont la
        // parité est cassée, elles sont elles-mêmes désorientées et peuvent
        // aggraver le désordre. L'ordre correct est donc : EXTRAIRE d'abord —
        // chaque objet repart d'une accolade réelle, donc d'une parité saine —
        // puis réparer CHAQUE fragment isolément.
        let salvaged = recommendationObjects(in: raw).compactMap { fragment -> [String: Any]? in
            let repairedFragment = LenientJSON.repairSyntax(LenientJSON.repaired(fragment))
            guard let data = repairedFragment.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let drafts = collect(salvaged)
        guard !drafts.isEmpty else {
            // Un profil lisible mais aucun objet de recommandation : le modèle
            // a dépensé tout son budget de sortie dans le préambule. Le dire
            // précisément vaut mieux qu'un « pas exploitable » générique — la
            // seule action utile est de changer de backend, pas de relancer.
            if let profile = salvagedProfile(in: raw) {
                return Result(profileSummary: profile, drafts: [],
                              failure: .truncatedBeforeRecommendations)
            }
            return Result(profileSummary: nil, drafts: [], failure: .unreadable)
        }
        return Result(profileSummary: salvagedProfile(in: raw), drafts: drafts,
                      failure: nil, wasSalvaged: true)
    }

    // MARK: - Analyse découpée en passes

    /// Fusionne les recommandations de plusieurs passes.
    ///
    /// C'est le « reduce » du découpage, et il est DÉTERMINISTE : deux passes
    /// qui repèrent le même sujet (l'abonnement vu à la fois dans les charges
    /// récurrentes et dans les marchands) produisent la même `ref` — on garde
    /// celle dont le modèle est le plus sûr, jamais les deux.
    ///
    /// ⚠️ Départage STABLE en cas d'égalité de confiance : sans lui, l'ordre
    /// des passes déciderait, et deux analyses du même dossier pourraient
    /// garder des variantes différentes du même conseil.
    static func merge(_ batches: [[CoachRecommendationDraft]]) -> [CoachRecommendationDraft] {
        var best: [String: CoachRecommendationDraft] = [:]
        var order: [String] = []
        for batch in batches {
            for draft in batch {
                guard let existing = best[draft.ref] else {
                    best[draft.ref] = draft
                    order.append(draft.ref)
                    continue
                }
                if draft.confidence > existing.confidence
                    || (draft.confidence == existing.confidence && draft.annualImpact > existing.annualImpact) {
                    best[draft.ref] = draft
                }
            }
        }
        return Array(order.compactMap { best[$0] }.prefix(maxRecommendations))
    }

    /// Lit une réponse qui ne porte QUE le profil (passe finale d'une analyse
    /// découpée). Tolérante de la même façon que `parse` : JSON valide d'abord,
    /// récupération au fil du texte ensuite.
    static func parseProfileOnly(_ raw: String) -> String? {
        let cleaned = LenientJSON.repairSyntax(LenientJSON.repaired(LenientJSON.extractObject(from: raw)))
        if let data = cleaned.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = profileKeys.compactMap({ root[$0] as? String }).first {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return salvagedProfile(in: raw)
    }

    /// Clés dont la présence en tête d'objet identifie une recommandation.
    private static let recognisableKeys: Set<String> = [
        "key", "title", "detail", "rationale", "category", "annual_impact", "effort", "confidence"
    ]

    /// Extrait les objets de recommandation d'un document cassé, en
    /// appariant les accolades LOCALEMENT à partir de chaque candidat.
    private static func recommendationObjects(in text: String) -> [String] {
        var results: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "{", startsRecommendation(text, at: index) else {
                index = text.index(after: index)
                continue
            }
            // Appariement à partir d'ici : `inString` repart de false, ce qui
            // est exact puisqu'on est sur une accolade structurelle.
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = index
            var closed: String.Index?

            while cursor < text.endIndex {
                let character = text[cursor]
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { closed = cursor; break }
                }
                cursor = text.index(after: cursor)
            }

            guard let closed else { break }   // objet tronqué : rien après lui
            results.append(String(text[index...closed]))
            index = text.index(after: closed)
        }
        return results
    }

    /// `true` si l'accolade en `position` ouvre un objet dont la première clé
    /// est une clé de recommandation.
    private static func startsRecommendation(_ text: String, at position: String.Index) -> Bool {
        var cursor = text.index(after: position)
        while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
        guard cursor < text.endIndex, text[cursor] == "\"" else { return false }
        cursor = text.index(after: cursor)
        var identifier = ""
        while cursor < text.endIndex, text[cursor] != "\"" {
            identifier.append(text[cursor])
            cursor = text.index(after: cursor)
            if identifier.count > 32 { return false }
        }
        return recognisableKeys.contains(identifier)
    }

    /// Récupère le profil quand le document est cassé — au mieux, sans rien
    /// inventer : on lit la chaîne qui suit `"profile":` et on retire la
    /// queue parasite (`\n[{`) que le modèle y a collée en oubliant la clé
    /// `recommendations`.
    private static func salvagedProfile(in text: String) -> String? {
        for key in profileKeys {
            guard let keyRange = text.range(of: "\"\(key)\"") else { continue }
            var cursor = keyRange.upperBound
            while cursor < text.endIndex, text[cursor] != "\"" {
                if text[cursor] == "}" || text[cursor] == "[" { break }
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == "\"" else { continue }
            cursor = text.index(after: cursor)
            var value = ""
            var escaped = false
            while cursor < text.endIndex {
                let character = text[cursor]
                if escaped { value.append(character); escaped = false }
                else if character == "\\" { value.append(character); escaped = true }
                else if character == "\"" { break }
                else { value.append(character) }
                cursor = text.index(after: cursor)
            }
            // La queue collée par le modèle : « …aiguë.\n[{ ».
            var cleanedValue = value
            while let last = cleanedValue.last, "[{ \t\n".contains(last) {
                cleanedValue.removeLast()
            }
            if cleanedValue.hasSuffix("\\n") { cleanedValue.removeLast(2) }
            let trimmed = cleanedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Convertit et déduplique une liste d'objets bruts.
    private static func collect(_ rawItems: [[String: Any]]) -> [CoachRecommendationDraft] {
        var drafts: [CoachRecommendationDraft] = []
        var seenRefs = Set<String>()
        for item in rawItems {
            guard let draft = draft(from: item) else { continue }
            // Un modèle repropose parfois deux fois le même sujet sous deux
            // formulations. La table a un UNIQUE (domain, ref) : sans cette
            // déduplication, la seconde écraserait la première en silence.
            guard seenRefs.insert(draft.ref).inserted else { continue }
            drafts.append(draft)
            if drafts.count >= maxRecommendations { break }
        }
        return drafts
    }

    // MARK: - Une recommandation

    private static func draft(from item: [String: Any]) -> CoachRecommendationDraft? {
        guard let title = string(item["title"]), !title.isEmpty else { return nil }
        let detail = string(item["detail"]) ?? ""
        // Un conseil sans explication n'est pas exploitable — mais on ne le
        // rejette pas pour autant : le titre seul reste une information.
        let rationale = string(item["rationale"])
        let category = string(item["category"])

        let normalized = CoachRanker.normalize(
            annualImpact: number(item["annual_impact"]) ?? 0,
            effort: Int(number(item["effort"]) ?? 3),
            confidence: number(item["confidence"]) ?? 0.5
        )

        // Clé stable : celle du modèle si elle est utilisable, sinon dérivée
        // du titre.
        let modelKey = string(item["key"]).map(CoachRecommendationDraft.slug) ?? ""
        let ref = modelKey.isEmpty ? CoachRecommendationDraft.slug(title) : modelKey
        guard !ref.isEmpty else { return nil }

        return CoachRecommendationDraft(
            ref: ref,
            title: title,
            detail: detail,
            rationale: rationale,
            category: category,
            annualImpact: normalized.annualImpact,
            effort: normalized.effort,
            confidence: normalized.confidence
        )
    }

    // MARK: - Lecture tolérante

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// ⚠️ Un modèle rend indifféremment `120`, `120.5` ou `"120,50"` — et le
    /// dernier cas est fréquent quand il répond en français. Les trois doivent
    /// donner le même nombre, sinon l'impact tombe à 0 et la recommandation
    /// dégringole dans le classement pour une raison purement typographique.
    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            let normalized = s
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return Double(normalized)
        }
        return nil
    }
}
