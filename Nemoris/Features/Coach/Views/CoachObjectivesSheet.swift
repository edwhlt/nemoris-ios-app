import SwiftUI

// MARK: - CoachObjectivesSheet
//
// Les objectifs que l'utilisateur écrit lui-même. C'est le seul endroit de
// l'app où il DICTE au coach ce qui compte pour lui — sans quoi les
// recommandations ne peuvent être qu'un optimum générique (« dépense moins »)
// au lieu d'un chemin vers ce qu'il veut vraiment.
//
// ⚠️ Texte SYNCHRONISÉ (`coach_profile` est dans `SyncSchema.syncedTables`) :
// c'est de la prose écrite à la main, la retaper sur un second appareil serait
// une friction inutile. Tout le reste du coach (analyses, recommandations)
// reste local et régénérable.

struct CoachObjectivesSheet: View {
    /// ⚠️ Les objectifs sont propres au DOMAINE depuis la migration v50 : un
    /// « mieux diversifier » écrit une fois pour toutes contaminait l'analyse
    /// des dépenses, qui ne voit aucun portefeuille et ne pouvait donc que
    /// s'en excuser ou l'ignorer (retour d'usage 2026-09-02).
    let domain: CoachDomain

    @Environment(CoachStore.self) private var store
    @Environment(\.paneDismiss) private var dismiss

    @State private var text: String = ""
    @State private var hasLoaded = false

    /// Exemples volontairement CONCRETS et chiffrés : un objectif vague
    /// (« mieux gérer mon argent ») ne donne au modèle aucune prise, et c'est
    /// exactement ce qu'un utilisateur écrit spontanément si on ne lui montre
    /// pas à quoi ressemble un objectif exploitable.
    ///
    /// Ils sont propres au domaine : proposer « investir 200 €/mois en ETF »
    /// dans l'écran des dépenses inviterait à réécrire l'objectif que ce
    /// coach-là ne peut pas servir.
    private var placeholder: String {
        switch domain {
        case .transactions:
            return """
            Exemples :
            • Mettre 400 € de côté chaque mois pour un apport immobilier d'ici 3 ans.
            • Réduire mon budget courses de 15 % sans changer d'enseigne.
            • Arrêter de payer des abonnements que je n'utilise pas.
            • Ne plus dépasser 150 €/mois de sorties et livraisons.
            """
        case .investments:
            return """
            Exemples :
            • Investir 200 €/mois en ETF, sans toucher au reste.
            • Ne pas dépasser 25 % du portefeuille sur une seule ligne.
            • Faire travailler les liquidités qui dorment sur le compte-titres.
            • Réduire les frais de courtage sur mes ordres récurrents.
            """
        }
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .font(AppTheme.Typography.bodyMedium)
                    .scrollContentBackground(.hidden)
            } header: {
                Text(domain == .transactions ? "Mes objectifs de dépenses" : "Mes objectifs d'investissement")
            } footer: {
                Text(domain == .transactions
                     ? "Écris-les avec tes mots, et si possible avec des montants et des échéances. Le coach dépenses les traite comme sa priorité n°1 et s'y réfère dans chaque recommandation. Tes objectifs d'investissement se saisissent séparément, dans le coach investissement."
                     : "Écris-les avec tes mots, et si possible avec des montants et des échéances. Le coach investissement les traite comme sa priorité n°1 et s'y réfère dans chaque recommandation. Tes objectifs de dépenses se saisissent séparément, dans le coach dépenses.")
                    .font(.caption)
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("À quoi ressemble un objectif exploitable") {
                    Text(placeholder)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Section {
                Text("Ces objectifs sont synchronisés entre tes appareils via iCloud. Les analyses et les recommandations, elles, restent locales — elles se régénèrent à partir de tes données.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .nemorisFormStyle()
        .tint(AppTheme.Colors.accent)
        .onAppear {
            // Une seule fois : sans ce garde, un re-rendu écraserait la saisie
            // en cours par la valeur persistée.
            guard !hasLoaded else { return }
            text = store.profile(for: domain).objectives
            hasLoaded = true
        }
        .paneChrome(domain == .transactions ? "Objectifs de dépenses" : "Objectifs d'investissement",
                    cancelLabel: "Annuler", onCancel: { dismiss() },
                    confirmLabel: "Enregistrer", confirmIcon: "checkmark") {
            store.saveObjectives(text, for: domain)
            dismiss()
        }
    }
}
