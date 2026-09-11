import SwiftUI

// MARK: - CoachObjectivesSheet
//
// The goals the user writes themselves. This is the only place in the app
// where they DICTATE to the coach what matters to them — without it,
// recommendations can only be a generic optimum ("spend less") instead of a
// path toward what they actually want.
//
// This text is SYNCED (`coach_profile` is in `SyncSchema.syncedTables`):
// it's hand-written prose, and retyping it on a second device would be
// needless friction. Everything else in the coach (analyses,
// recommendations) stays local and regenerable.

struct CoachObjectivesSheet: View {
    /// Goals are per-DOMAIN. A "diversify better" written once and shared
    /// would contaminate the spending analysis, which sees no portfolio and
    /// could therefore only apologize for it or ignore it.
    let domain: CoachDomain

    @Environment(CoachStore.self) private var store
    @Environment(\.paneDismiss) private var dismiss

    @State private var text: String = ""
    @State private var hasLoaded = false

    /// Deliberately CONCRETE, quantified examples: a vague goal ("manage my
    /// money better") gives the model nothing to grip, and that's exactly
    /// what a user writes spontaneously unless shown what an actionable goal
    /// looks like.
    ///
    /// They are per-domain: offering "invest €200/month in ETFs" on the
    /// spending screen would invite writing a goal that this particular
    /// coach cannot serve.
    // `LocalizedStringKey` (not `String`): passed to `Text(placeholder)`
    // below, a `String`-typed property would resolve to the verbatim Text
    // init and never localize regardless of Localizable.strings content —
    // cf. CLAUDE.md §5. No interpolation here, so no `%` to escape.
    private var placeholder: LocalizedStringKey {
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
            // Once only: without this guard, a re-render would overwrite the
            // in-progress edit with the persisted value.
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
