import SwiftUI

/// Pending Apple Pay expenses, shown separately — never mixed into the
/// Budget/Dashboard totals until they have been resolved (neither the
/// engine-on-launch path nor matching against a bank statement import is
/// implemented yet). Opened from the Dashboard card. Grouped by calendar
/// week, with each group's total written in its header.
struct PendingApplePayListView: View {
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState

    @State private var entries: [PendingApplePayEntry] = []
    @State private var showSettings = false
    /// An entry dropped off without a known amount (see
    /// `ImportTransactionApplePayEntityIntent`) being corrected — drives the
    /// input alert.
    @State private var correctingEntry: PendingApplePayEntry?
    @State private var amountInput: String = ""

    private let repository = PendingApplePayRepository()

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    icon: "creditcard.and.123",
                    title: "Aucune dépense en attente",
                    message: "Les paiements Apple Pay déposés par ton automatisation Raccourcis apparaîtront ici, avant leur catégorisation."
                )
            } else {
                List {
                    ForEach(weekGroups) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                row(for: entry)
                            }
                        } header: {
                            weekHeader(for: group)
                        }
                    }
                }
                .listStyle(.plain)
                #if os(macOS)
                .scrollContentBackground(.hidden)
                #endif
                .background(AppTheme.Colors.background)
            }
        }
        .paneChrome(
            "Apple Pay en attente",
            cancelLabel: "Fermer", onCancel: { paneDismiss() },
            confirmLabel: "Réglages", confirmIcon: "gearshape", onConfirm: { showSettings = true }
        )
        .tint(AppTheme.Colors.accent)
        .task(id: appState.dataRefreshToken) { load() }
        .onAppear(perform: load)
        .adaptivePane(isPresented: $showSettings) {
            // The banner/list is only visible once the shortcut has
            // dropped off at least one entry — so installation has no place
            // here, unlike the Settings entry.
            ApplePayAlertSettingsView(showsInstallSection: false)
        }
        .alert(
            "Saisir le montant",
            isPresented: Binding(
                get: { correctingEntry != nil },
                set: { if !$0 { correctingEntry = nil } }
            )
        ) {
            TextField("Montant", text: $amountInput)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Button("Annuler", role: .cancel) {}
            Button("Enregistrer", action: saveCorrectedAmount)
        } message: {
            if let entry = correctingEntry {
                Text("Le montant de \"\(entry.merchant)\" n'était pas connu au moment du paiement.")
            }
        }
    }

    // MARK: - Weekly grouping

    private struct WeekGroup: Identifiable {
        let weekStart: Date
        let entries: [PendingApplePayEntry]
        var id: Date { weekStart }
        var total: Double { entries.reduce(0) { $0 + abs($1.amount) } }
    }

    /// Calendar week (Monday-Sunday, fixed ISO 8601), most recent first.
    /// Calls EXACTLY the same function as the threshold alert
    /// (`ApplePayAlertPeriod.week.start(from:)`) rather than a second ad hoc
    /// implementation: computing the start of the week here with
    /// `Calendar.current` (region-dependent, and running in the foreground
    /// process) while the alert computed it separately from the Shortcuts
    /// automation's background execution meant two implementations that
    /// could diverge on the very definition of "this week".
    private var weekGroups: [WeekGroup] {
        let grouped = Dictionary(grouping: entries) { entry in
            ApplePayAlertPeriod.week.start(from: entry.createdAt)
        }
        return grouped
            .map { start, items in
                WeekGroup(weekStart: start, entries: items.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted { $0.weekStart > $1.weekStart }
    }

    @ViewBuilder
    private func weekHeader(for group: WeekGroup) -> some View {
        HStack {
            weekLabel(group.weekStart)
            Spacer()
            MoneyText(
                amount: group.total,
                font: AppTheme.Typography.labelLarge,
                color: AppTheme.Colors.textSecondary
            )
        }
    }

    /// "This week" / "Last week" when it lines up, otherwise "Week of
    /// August 25" — the date stays a `Text(_, format:)` so it honours the
    /// environment locale (never a concatenated `String` literal).
    @ViewBuilder
    private func weekLabel(_ start: Date) -> some View {
        let calendar = Calendar.applePayWeek
        let now = Date()
        let currentStart = ApplePayAlertPeriod.week.start(from: now)
        if calendar.isDate(start, inSameDayAs: currentStart) {
            Text("Cette semaine")
        } else if let lastWeekRef = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
                  calendar.isDate(start, inSameDayAs: ApplePayAlertPeriod.week.start(from: lastWeekRef)) {
            Text("Semaine dernière")
        } else {
            Text("Semaine du ") + Text(start, format: .dateTime.day().month(.wide))
        }
    }

    @ViewBuilder
    private func row(for entry: PendingApplePayEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AppTheme.Colors.accentSecondary))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.merchant)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(entry.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            if isAmountUnknown(entry) {
                Label("À saisir", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.Colors.warning)
            } else {
                MoneyText(amount: entry.amount, font: AppTheme.Typography.bodyMedium)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isAmountUnknown(entry) else { return }
            correctingEntry = entry
            amountInput = ""
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                dismiss(entry)
            } label: {
                Label("Écarter", systemImage: "xmark.circle")
            }
        }
    }

    /// Dropped off by the shortcut without a known amount at payment time
    /// (see `ImportTransactionApplePayEntityIntent`) — stored as 0, to be
    /// corrected manually. `abs`: the amount is always negative once known.
    private func isAmountUnknown(_ entry: PendingApplePayEntry) -> Bool {
        abs(entry.amount) < 0.005
    }

    private func load() {
        entries = repository.fetchEntries(status: .pending)
    }

    private func saveCorrectedAmount() {
        guard let entry = correctingEntry else { return }
        let normalized = amountInput.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return }
        repository.updateAmount(id: entry.id, amount: value)
        load()
        // Screen already in the foreground: bump directly, like `dismiss(_:)`.
        appState.dataRefreshToken = UUID()
    }

    private func dismiss(_ entry: PendingApplePayEntry) {
        repository.updateStatus(id: entry.id, to: .dismissed)
        load()
        // Screen already in the foreground (unlike the background drop-off
        // by the Shortcuts automation): the bump can happen directly, with
        // no need for the cross-process notification.
        appState.dataRefreshToken = UUID()
    }
}
