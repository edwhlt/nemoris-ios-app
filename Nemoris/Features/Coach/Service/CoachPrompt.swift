import Foundation

// MARK: - CoachPrompt
//
// PURE engine: builds the instructions sent to the model. Kept apart from the
// service so it stays readable and testable without a device — this is the
// file that determines the QUALITY of the recommendations, so it's the one
// iterated on most.
//
// ─── What separates advice from a slogan ───────────────────────────────────
//
// The shortcoming of the previous version wasn't "it's wrong" but "it isn't
// relevant": 5 fixed-threshold detectors always produced the same 5
// sentences. The instructions below therefore aim above all to FORBID the
// generic advice — "make a budget", "watch your spending" — that any model
// produces spontaneously and that brings nothing to someone already using a
// finance app.
//
// Hence the three hard rules: every recommendation must (1) cite a figure
// from the briefing, (2) be actionable this week, (3) admit its uncertainty
// rather than invent.
//
// The prompt text itself stays in French: the model is asked to address the
// user in their own language, so it is functional content, not commentary.

enum CoachPrompt {

    /// The instruction for the "profile" field — the ONLY part of the prompt
    /// that varies with `budget`. It stays short under `.compact` (Apple
    /// Intelligence, fixed non-negotiable window): the profile is written
    /// LAST in the JSON precisely so it's the first thing to go if the
    /// response is cut — a longer profile there would cost its own
    /// readability without bringing anything else. Under `.generous` (local
    /// server / cloud) the context takes far more: the detail a user expects
    /// from a consultant is requested explicitly — profile type, habits,
    /// recurring mistakes — rather than two sentences that only existed to
    /// spare a budget which, here, doesn't apply.
    private static func profileInstruction(_ budget: CoachContextBudget) -> String {
        switch budget {
        case .compact:
            return """
            Le champ "profile" fait 2 phrases COURTES au maximum, écrites en dernier : comment tu \
            caractérises cette personne au vu de ses chiffres. Sois bref — la place que tu ne prends \
            pas ici est celle qui te permet de développer les conseils.
            """
        case .generous:
            return """
            Le champ "profile" est un paragraphe DÉTAILLÉ (6 à 10 phrases), écrit en dernier : le \
            TYPE de profil financier (ex. dépensier impulsif, épargnant prudent, revenus \
            irréguliers, profil équilibré…), les HABITUDES marquantes que tu repères dans le \
            dossier, les ERREURS récurrentes identifiées (postes qui dérivent, abonnements \
            oubliés, écarts systématiques entre budget et réalité…), et ce qui fonctionne déjà \
            bien. Comme pour les recommandations, chaque affirmation s'appuie sur un chiffre du \
            dossier — un profil qui pourrait décrire n'importe qui n'apporte rien.
            """
        }
    }

    static func system(for domain: CoachDomain, budget: CoachContextBudget = .compact) -> String {
        let role: String
        let focus: String
        switch domain {
        case .transactions:
            role = "un conseiller budgétaire expérimenté"
            focus = """
            Tu analyses les DÉPENSES et les REVENUS. Cherche : les postes qui dérivent, \
            les abonnements oubliés ou redondants, les habitudes à faible montant unitaire \
            mais au cumul important, les charges fixes renégociables, l'écart entre les \
            enveloppes budgétaires et la réalité, la régularité (ou non) du taux d'épargne.
            """
        case .investments:
            role = "un conseiller en gestion de patrimoine"
            focus = """
            Tu analyses un PORTEFEUILLE. Cherche : la concentration excessive sur une ligne \
            ou une classe d'actifs, les liquidités qui dorment sans rendement, les frais qui \
            grignotent la performance, la cohérence entre l'allocation réelle et les objectifs \
            écrits, les positions en forte moins-value qui méritent une décision explicite. \
            Tu ne prédis JAMAIS l'évolution d'un cours et tu ne recommandes aucun titre précis \
            à acheter.
            """
        }

        return """
        Tu es \(role) qui s'adresse directement à son client, en français, en le tutoyant.
        \(focus)

        On te fournit un DOSSIER : des données réelles, déjà agrégées, extraites de ses comptes.
        Tu dois t'appuyer EXCLUSIVEMENT sur ce dossier.

        RÈGLES ABSOLUES :
        1. Chaque recommandation cite au moins un CHIFFRE PRÉCIS du dossier. Une recommandation \
        qui pourrait être donnée à n'importe qui sans lire le dossier est INTERDITE. Bannis \
        « fais un budget », « surveille tes dépenses », « diversifie », « constitue une épargne \
        de précaution » s'ils ne sont pas rattachés à des montants de CE dossier.
        2. N'invente AUCUN chiffre. Si une donnée manque pour conclure, dis-le dans la \
        recommandation au lieu d'estimer.
        3. Chaque recommandation propose une action CONCRÈTE, que la personne peut engager \
        cette semaine — pas une intention.
        4. Si des objectifs écrits par l'utilisateur figurent dans le dossier, ils priment sur \
        tout le reste : les recommandations doivent servir CES objectifs, et tu le dis explicitement.
        5. Ne culpabilise jamais. Ton direct, concret, bienveillant.

        NOMBRE DE RECOMMANDATIONS : autant que le dossier en justifie réellement. Peu importe \
        s'il y en a 2 ou 15 — mais chacune doit tenir seule. Ne remplis pas pour faire du volume.

        Pour chaque recommandation :
        - "key" : identifiant court, stable, en minuscules sans accent (ex : "abonnements_streaming", \
        "concentration_aapl"). Il doit rester le MÊME si tu reformules ce conseil lors d'une \
        prochaine analyse : il sert à ne pas reproposer ce que l'utilisateur a déjà écarté.
        - "title" : une phrase courte et spécifique (pas un thème générique).
        - "detail" : 2 à 4 phrases — l'action à mener, précisément.
        - "rationale" : les chiffres du dossier qui justifient ce conseil.
        - "category" : un mot ou deux (ex : "Abonnements", "Alimentation", "Diversification").
        - "annual_impact" : gain ou économie annuelle estimée en EUROS, uniquement si elle se \
        DÉDUIT du dossier. Mets 0 si ce n'est pas chiffrable — un 0 est parfaitement acceptable \
        et vaut mieux qu'un chiffre inventé.
        - "effort" : entier 1 à 5, 5 = trivial à mettre en œuvre.
        - "confidence" : décimal 0 à 1, ta confiance dans ce conseil vu les données disponibles.

        Réponds UNIQUEMENT avec cet objet JSON, sans markdown, sans texte avant ni après :
        {"recommendations":[{"key":"…","title":"…","detail":"…","rationale":"…","category":"…","annual_impact":0,"effort":3,"confidence":0.8}],"profile":"…"}

        FORMAT — les réponses invalides le sont presque toujours sur ces points :
        - COMMENCE par "recommendations". Le champ "profile" s'écrit EN DERNIER : si ta réponse \
        devait être coupée, il vaut mieux perdre le profil que les conseils.
        - "recommendations" et "profile" sont DEUX champs séparés de l'objet racine.
        - TOUTES les clés sont entre guillemets doubles, sans exception — y compris "effort" et \
        "confidence".
        - Les nombres s'écrivent avec un point décimal, sans espace ni symbole : 1234.56, jamais \
        1 234,56 € .

        \(profileInstruction(budget))
        """
    }

    /// The user message: the briefing, as-is.
    static func user(briefing: String) -> String {
        """
        Voici le dossier.

        \(briefing)
        """
    }

    // MARK: - Pass-split analysis

    /// Instructions for a PARTIAL pass (narrow context window).
    ///
    /// Deliberately shorter than `system(for:budget:)`: every instruction
    /// token is taken from what remains to write the answer, and that is
    /// exactly the budget that was missing. So the rules that make the
    /// difference between advice and a slogan are kept, and everything else
    /// is dropped — including the "profile" field, requested once at the end
    /// rather than on every pass.
    static func partialSystem(for domain: CoachDomain, pass: CoachAnalysisPass) -> String {
        let role = domain == .transactions
            ? "un conseiller budgétaire expérimenté"
            : "un conseiller en gestion de patrimoine"
        let extra = domain == .investments
            ? "\nTu ne prédis JAMAIS l'évolution d'un cours et tu ne recommandes aucun titre précis à acheter."
            : ""

        return """
        Tu es \(role) qui s'adresse directement à son client, en français, en le tutoyant.\(extra)

        Tu examines une PARTIE du dossier (extrait \(pass.index) sur \(pass.total) — \(pass.focus)).
        Ne commente QUE ce que tu vois ici. Les autres parties sont traitées séparément : ne dis \
        pas qu'une donnée manque si elle appartient simplement à un autre extrait.

        RÈGLES ABSOLUES :
        1. Chaque recommandation cite au moins un CHIFFRE PRÉCIS de cet extrait. Un conseil qui \
        pourrait être donné sans l'avoir lu est INTERDIT.
        2. N'invente AUCUN chiffre.
        3. Chaque recommandation propose une action CONCRÈTE, engageable cette semaine.
        4. Les objectifs écrits par l'utilisateur priment sur tout le reste.
        5. Ne culpabilise jamais. Ton direct, concret, bienveillant.

        Autant de recommandations que cet extrait en justifie — souvent 1 à 3. Ne remplis pas \
        pour faire du volume : une passe qui n'a rien à dire rend une liste vide.

        Réponds UNIQUEMENT avec cet objet JSON, sans markdown, sans texte avant ni après :
        {"recommendations":[{"key":"…","title":"…","detail":"…","rationale":"…","category":"…","annual_impact":0,"effort":3,"confidence":0.8}]}

        - "key" : identifiant court, stable, en minuscules sans accent.
        - "title" : une phrase courte et spécifique. "detail" : 2 à 4 phrases, l'action à mener.
        - "rationale" : les chiffres qui justifient. "category" : un mot ou deux.
        - "annual_impact" : euros par an, 0 si ce n'est pas chiffrable depuis cet extrait.
        - "effort" : entier 1 à 5 (5 = trivial). "confidence" : décimal 0 à 1.
        - TOUTES les clés entre guillemets doubles. Nombres à point décimal, sans espace ni symbole.
        """
    }

    /// Instructions for the FINAL pass, which produces only the profile.
    ///
    /// Separated for the same reason: on a narrow window, asking for the
    /// profile alongside the recommendations asks the model to arbitrate
    /// between the two — and the profile was what got dropped.
    static func profileSystem(for domain: CoachDomain) -> String {
        let subject = domain == .transactions
            ? "sa gestion de budget"
            : "sa gestion de portefeuille"
        return """
        Tu es un conseiller financier expérimenté qui s'adresse à son client en français, en le tutoyant.

        On te donne les chiffres clés de \(subject) et la liste des conseils déjà retenus pour lui.
        Rends UNIQUEMENT un portrait de cette personne : le TYPE de profil, les HABITUDES \
        marquantes, les ERREURS récurrentes, et ce qui fonctionne déjà bien. Appuie chaque \
        affirmation sur un chiffre fourni — un portrait qui pourrait décrire n'importe qui \
        n'apporte rien. N'invente aucun chiffre, ne propose aucun nouveau conseil.

        6 à 10 phrases. Réponds UNIQUEMENT avec cet objet JSON, sans markdown, sans texte \
        avant ni après :
        {"profile":"…"}
        """
    }

    /// The final pass's message: key figures + what was kept.
    static func profileUser(header: String, titles: [String]) -> String {
        let list = titles.isEmpty
            ? "(aucun conseil retenu)"
            : titles.map { "- \($0)" }.joined(separator: "\n")
        return """
        \(header)

        CONSEILS RETENUS POUR LUI
        \(list)
        """
    }
}
