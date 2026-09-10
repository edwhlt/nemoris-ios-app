import Foundation

// MARK: - Coach — modèles
//
// Le coach est un CONSULTANT, pas un détecteur de seuils : il reçoit un
// dossier dense sur la situation de l'utilisateur (cf. `CoachBriefingBuilder`
// / `InvestmentBriefingBuilder`), plus les objectifs que celui-ci a écrits, et
// rend un diagnostic + un nombre NON PLAFONNÉ de recommandations.
//
// Ce que ça remplace : `InsightEngine`, 5 détecteurs à seuils fixes dont le
// texte était entièrement écrit en dur. Il n'est pas supprimé pour autant —
// il devient (1) un fournisseur de SIGNAUX injectés dans le dossier et (2) le
// repli quand aucune IA n'est disponible, comme chaque fonctionnalité IA de
// cette app.

/// Le budget de contexte alloué au dossier et aux consignes, selon le backend
/// RÉELLEMENT résolu pour la fonctionnalité — jamais le choix brut de
/// l'utilisateur, c'est ce que le modèle va effectivement recevoir qui compte.
///
/// ⚠️ Apple Intelligence (`LanguageModelSession`) n'expose AUCUN paramètre de
/// taille de contexte : la fenêtre est FIXE (de l'ordre de 4 000 tokens,
/// entrée + sortie confondues) et une réponse qui la dépasse échoue plutôt
/// que d'être tronquée proprement — `.compact` est calibré pour ce plafond,
/// sans marge de négociation possible côté app (cf. `CoachBriefingBuilder`,
/// `CoachPrompt`).
///
/// Un serveur local ou un fournisseur cloud a un contexte nettement plus
/// large (souvent 8k-128k+, et `AIFeature.maxOutputTokens` leur accorde déjà
/// 8 192 tokens de SORTIE) — les brider aux mêmes plafonds qu'Apple
/// Intelligence gaspillait cette marge sans raison : dossier tronqué plus
/// tôt qu'il ne devrait, profil réduit à 2 phrases y compris quand le modèle
/// aurait largement la place de détailler (retour d'usage 2026-08-29).
enum CoachContextBudget: Sendable, Equatable {
    /// Apple Intelligence — fenêtre fixe, non configurable.
    case compact
    /// Serveur local ou fournisseur cloud — contexte nettement plus large.
    case generous

    /// Depuis le backend RÉSOLU (jamais `.automatic`, qui n'est qu'une
    /// préférence brute) — `nil`/`.automatic`/`.off` retombent sur `.compact`
    /// par défaut prudent, mais ces cas ne devraient jamais atteindre un appel
    /// modèle réel (`AIBackendResolver.resolve` ne les renvoie jamais tels quels).
    /// Faut-il relancer l'analyse en passes courtes ?
    ///
    /// ⚠️ Le déclencheur n'est PAS « ça a échoué » mais « le serveur a montré
    /// sa vraie limite » : un modèle raisonnement qui rend de la réflexion
    /// tronquée et zéro réponse (mesuré trois fois sur qwen3.5-9b via LM
    /// Studio) dit exactement une chose — l'entrée qu'on lui envoie ne lui
    /// laisse pas de quoi conclure. On ne le devine pas à l'avance, puisque le
    /// même modèle réussit très bien sur une autre machine ; on l'apprend au
    /// premier appel, et on rejoue en découpé.
    ///
    /// Une seule relance : si les passes courtes échouent aussi, le problème
    /// n'est plus la taille de l'entrée, et boucler ferait juste attendre.
    static func shouldRetryInPasses(budget: CoachContextBudget,
                                    sawReasoningOnly: Bool,
                                    producedRecommendations: Bool,
                                    alreadyRetried: Bool) -> Bool {
        budget == .generous && sawReasoningOnly && !producedRecommendations && !alreadyRetried
    }

    static func resolved(from backend: AIBackendChoice?) -> CoachContextBudget {
        switch backend {
        case .localServer, .cloud: return .generous
        // Le modèle embarqué tourne avec le `LlamaConfig.maxTokenCount` fixé
        // par `EmbeddedModelManager` (4 096, comme Apple Intelligence) — même
        // budget prudent, pour la même raison : petit GGUF, contexte limité.
        case .foundationModels, .embeddedModel, .automatic, .off, nil: return .compact
        }
    }
}

/// Un bloc du dossier, nommé — la brique que le découpage en passes
/// distribue entre plusieurs appels quand le modèle ne peut pas tout lire
/// d'un coup (cf. `CoachPassPlanner`).
struct CoachBriefingSection: Sendable, Equatable {
    /// Identifiant stable, pour les tests et le diagnostic.
    let id: String
    /// Nom lisible, annoncé au modèle (« tu regardes : … »).
    let title: String
    /// Le bloc tel qu'il part au modèle, en-tête compris.
    let body: String
}

/// Une passe d'analyse : ce qu'on envoie au modèle en UNE fois.
///
/// Une seule passe pour un backend qui encaisse tout le dossier ; plusieurs
/// pour une fenêtre de contexte étroite — le dossier est alors découpé, et
/// les recommandations de chaque passe sont fusionnées ensuite. C'est le
/// pendant du « map » d'un map-reduce : le « reduce » est DÉTERMINISTE
/// (déduplication par `ref` + `CoachRanker`), pas un troisième appel modèle.
struct CoachAnalysisPass: Sendable, Equatable {
    /// 1-based, pour l'annoncer au modèle (« passe 2 sur 3 »).
    let index: Int
    let total: Int
    /// Les sections regardées dans cette passe, pour cadrer le modèle.
    let focus: String
    /// Le texte envoyé : chiffres clés + sections + objectifs.
    let body: String

    var isOnly: Bool { total <= 1 }
}

/// Les deux domaines d'expertise. Chacun a son propre backend IA
/// configurable : l'analyse est lourde et ponctuelle, on peut vouloir un
/// modèle cloud ici et Apple Intelligence pour le reste de l'app.
enum CoachDomain: String, CaseIterable, Identifiable, Sendable {
    case transactions
    case investments

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transactions: return "Coach dépenses"
        case .investments:  return "Coach investissement"
        }
    }

    var icon: String {
        switch self {
        case .transactions: return "lightbulb"
        case .investments:  return "chart.line.uptrend.xyaxis"
        }
    }

    /// La fonctionnalité IA correspondante (réglage de backend par domaine).
    ///
    /// ⚠️ `.insights` conserve son `rawValue` historique : c'est la clé sous
    /// laquelle le choix de backend de l'utilisateur est déjà persisté
    /// (`ai.backend.insights`). Le renommer perdrait son réglage en silence.
    var aiFeature: AIFeature {
        switch self {
        case .transactions: return .insights
        case .investments:  return .investmentCoach
        }
    }
}

/// Cycle de vie d'une recommandation, PRÉSERVÉ d'une analyse à l'autre grâce à
/// la clé stable `ref` : rejeter une recommandation la garde rejetée même si
/// le modèle la repropose la semaine suivante.
enum CoachRecommendationStatus: String, Sendable {
    case new
    case seen
    case done
    case dismissed

    var isVisible: Bool { self == .new || self == .seen }
}

struct CoachRecommendation: Identifiable, Hashable, Sendable {
    let id: Int
    let domain: CoachDomain
    /// Clé stable inter-analyses (fournie par le modèle, sinon dérivée du titre).
    let ref: String
    var title: String
    var detail: String
    /// Le RAISONNEMENT : sur quels chiffres du dossier le modèle s'appuie.
    /// C'est ce qui distingue un conseil d'un slogan, et ce qui permet à
    /// l'utilisateur de juger si la recommandation tient.
    var rationale: String?
    /// Libellé libre rendu par le modèle (« Abonnements », « Diversification »…).
    /// Volontairement pas un enum : figer une taxonomie ramènerait la rigidité
    /// des 5 `InsightKind` qu'on quitte.
    var category: String?
    /// Gain (ou coût évité) annuel estimé, en euros. 0 = non chiffrable.
    var annualImpact: Double
    /// Faisabilité 1-5 (5 = trivial).
    var effort: Int
    /// Confiance 0-1 auto-évaluée par le modèle, bornée à l'écriture.
    var confidence: Double
    var status: CoachRecommendationStatus
    var generatedAt: Date

    static func == (lhs: CoachRecommendation, rhs: CoachRecommendation) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Ce que le modèle a compris de la situation, pour UN domaine.
struct CoachAnalysis: Sendable {
    let domain: CoachDomain
    /// Le « profil type » : quelques phrases qui caractérisent l'utilisateur.
    var profileSummary: String?
    var generatedAt: Date?
    var isError: Bool
    var message: String?
    /// Backend qui a produit l'analyse, pour la traçabilité (« Claude », …).
    var backend: String?
    /// Extrait de la réponse BRUTE du modèle, conservé uniquement en cas
    /// d'échec de lecture. C'est la seule façon de distinguer « le modèle a
    /// refusé », « il a répondu à côté » et « il a été coupé en plein JSON » —
    /// sans lui, l'erreur est indiagnosticable (retour d'usage 2026-08-28).
    var rawResponse: String?

    static func empty(_ domain: CoachDomain) -> CoachAnalysis {
        CoachAnalysis(domain: domain, profileSummary: nil, generatedAt: nil,
                      isError: false, message: nil, backend: nil, rawResponse: nil)
    }

    /// Au-delà de ce délai, l'analyse est considérée périmée et une relance
    /// AUTOMATIQUE est autorisée (asynchrone et non bloquante — cf. `CoachStore`).
    static let stalenessInterval: TimeInterval = 7 * 24 * 3600

    func isStale(now: Date = Date()) -> Bool {
        guard let generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > Self.stalenessInterval
    }
}

/// Recommandation telle qu'elle sort du modèle, AVANT persistance : pas
/// encore d'`id`, pas encore de `status` (le repository conserve celui de la
/// ligne existante s'il y en a une).
struct CoachRecommendationDraft: Sendable {
    var ref: String
    var title: String
    var detail: String
    var rationale: String?
    var category: String?
    var annualImpact: Double
    var effort: Int
    var confidence: Double

    /// Fabrique une clé stable à partir du texte quand le modèle n'en fournit
    /// pas d'utilisable.
    ///
    /// ⚠️ La stabilité de cette clé est ce qui fait tenir tout le mécanisme de
    /// rejet persistant. Elle est volontairement dérivée d'un texte NORMALISÉ
    /// (minuscules, accents et ponctuation retirés, tronqué) : deux analyses
    /// successives reformulent presque toujours légèrement le même conseil, et
    /// une clé calculée sur le titre brut changerait à chaque fois.
    static func slug(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        let allowed = folded.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "_"
        }
        let collapsed = String(allowed)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return String(collapsed.prefix(60))
    }
}

/// Les objectifs écrits par l'utilisateur — la seule partie SYNCHRONISÉE
/// (prose authored, pénible à retaper sur un second appareil).
struct CoachProfile: Sendable {
    var objectives: String
    var updatedAt: Date?

    static let empty = CoachProfile(objectives: "", updatedAt: nil)

    var hasObjectives: Bool {
        !objectives.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
