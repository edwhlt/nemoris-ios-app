import SwiftUI

/// Sélecteur rapide de mois/année — ouvert en tapant le libellé mois/année
/// de `MonthNavigationView` (retour d'usage : "faire de l'affichage du mois
/// et de l'année ... des boutons pour sélectionner le mois et l'année").
/// Deux roues (mois, année) plutôt qu'un `DatePicker` : celui-ci n'a pas de
/// mode "mois + année seuls" sans jour, et afficherait un sélecteur de jour
/// inutile pour ce cas d'usage.
struct MonthYearPickerSheet: View {
    let month: Date
    let onPick: (Date) -> Void

    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var selectedMonthIndex: Int
    @State private var selectedYear: Int

    /// ±15 ans autour de l'année courante — largement assez pour un usage
    /// budget personnel, sans liste interminable.
    private static var yearRange: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 15)...(current + 5))
    }

    init(month: Date, onPick: @escaping (Date) -> Void) {
        self.month = month
        self.onPick = onPick
        let cal = Calendar.current
        _selectedMonthIndex = State(initialValue: cal.component(.month, from: month) - 1)
        _selectedYear = State(initialValue: cal.component(.year, from: month))
    }

    /// Noms de mois dans la langue de l'app (pas celle, potentiellement
    /// différente, de l'appareil) — même convention que `weekdaySymbols`
    /// dans `BudgetView`.
    private var monthSymbols: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = appState.locale
        return cal.standaloneMonthSymbols
    }

    private func resetToToday() {
        let cal = Calendar.current
        let now = Date()
        selectedMonthIndex = cal.component(.month, from: now) - 1
        selectedYear = cal.component(.year, from: now)
    }

    var body: some View {
        Group {
            #if os(macOS)
            // `.wheel` n'existe pas sur macOS (iOS/watchOS uniquement) — un
            // `Form` groupé (convention `nemorisFormStyle()`, cf. CLAUDE.md
            // §N.1) au lieu d'un `HStack` flottant dans un `VStack` vide :
            // ce dernier laissait les deux pickers écartés sans repère visuel
            // au milieu du panneau (retour d'usage 2026-08-26, capture à
            // l'appui).
            Form {
                Section {
                    Picker("Mois", selection: $selectedMonthIndex) {
                        ForEach(Array(monthSymbols.enumerated()), id: \.offset) { i, name in
                            Text(name.capitalized).tag(i)
                        }
                    }
                    Picker("Année", selection: $selectedYear) {
                        ForEach(Self.yearRange, id: \.self) { y in
                            Text(String(y)).tag(y)
                        }
                    }
                }
                Section {
                    Button(action: resetToToday) {
                        Label("Aujourd'hui", systemImage: "arrow.uturn.left")
                    }
                }
            }
            .pickerStyle(.menu)
            .nemorisFormStyle()
            #else
            VStack(spacing: AppTheme.Spacing.lg) {
                HStack(spacing: 0) {
                    Picker("Mois", selection: $selectedMonthIndex) {
                        ForEach(Array(monthSymbols.enumerated()), id: \.offset) { i, name in
                            Text(name.capitalized).tag(i)
                        }
                    }
                    .pickerStyle(.wheel)
                    Picker("Année", selection: $selectedYear) {
                        ForEach(Self.yearRange, id: \.self) { y in
                            Text(String(y)).tag(y)
                        }
                    }
                    .pickerStyle(.wheel)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, AppTheme.Spacing.lg)

                Button(action: resetToToday) {
                    Label("Aujourd'hui", systemImage: "arrow.uturn.left")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.Colors.accent)
            }
            .padding(.bottom, AppTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
            .background(AppTheme.Colors.background)
            #endif
        }
        .tint(AppTheme.Colors.accent)
        .paneChrome(
            "Choisir un mois",
            cancelLabel: "Annuler", onCancel: { dismiss() },
            // Icône groupée avec le "✕" d'annulation dans la barre système
            // macOS (niveau inspecteur) — un "OK" en texte nu à côté d'un
            // "✕" icône seule créait un déséquilibre visuel (retour d'usage
            // 2026-08-26). Sans ambiguïté possible ici (pas d'action de
            // masse à distinguer d'un simple "valider"), contrairement à
            // "Tout accepter" (cf. commentaire de `InspectorChromeToolbar.barButton`).
            confirmLabel: "OK", confirmIcon: "checkmark",
            onConfirm: {
                var comps = DateComponents()
                comps.year = selectedYear
                comps.month = selectedMonthIndex + 1
                comps.day = 1
                let picked = Calendar.current.date(from: comps) ?? month
                dismiss()
                onPick(picked)
            }
        )
    }
}
