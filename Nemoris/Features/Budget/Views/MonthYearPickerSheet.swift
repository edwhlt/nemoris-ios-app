import SwiftUI

/// Quick month/year picker — opened by tapping the month/year label
/// on `MonthNavigationView`. Two wheels (month, year) rather than a
/// `DatePicker`: the latter has no "month + year only" mode with no day, and
/// would show a day picker that's useless for this use case.
struct MonthYearPickerSheet: View {
    let month: Date
    let onPick: (Date) -> Void

    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var selectedMonthIndex: Int
    @State private var selectedYear: Int

    /// ±15 years around the current year — more than enough for
    /// personal budgeting, with no endless list.
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

    /// Month names in the app's language (not the device's, which may
    /// differ) — the same convention as `weekdaySymbols`
    /// in `BudgetView`.
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
            // `.wheel` doesn't exist on macOS (iOS/watchOS only) — a
            // grouped `Form` (the `nemorisFormStyle()` convention, see CLAUDE.md
            // §N.1) instead of an `HStack` floating in an empty `VStack`:
            // the latter left the two pickers adrift with no visual anchor
            // in the middle of the pane.
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
            // The icon grouped with the "✕" cancel button in the macOS system
            // bar (inspector level) — a plain-text "OK" next to an
            // icon-only "✕" created a visual imbalance. No possible
            // ambiguity here (no bulk action to distinguish from a plain
            // "confirm"), unlike "Accept all" (see the comment on
            // `InspectorChromeToolbar.barButton`).
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
