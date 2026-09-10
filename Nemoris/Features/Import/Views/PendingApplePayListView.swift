import SwiftUI

/// Dépenses Apple Pay en attente, affichées "à part" — jamais mélangées aux
/// totaux Budget/Dashboard tant qu'elles n'ont pas été résolues (ouverture de
/// l'app → moteur, ou rapprochement à l'import du relevé bancaire — les deux
/// pas encore livrés). Ouverte depuis la carte du Dashboard. Groupées par
/// semaine calendaire, cumul écrit en en-tête de chaque groupe.
struct PendingApplePayListView: View {
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState

    @State private var entries: [PendingApplePayEntry] = []
    @State private var showSettings = false
    /// Entrée déposée sans montant connu (cf. `ImportTransactionApplePayEntityIntent`)
    /// en cours de correction — pilote l'alerte de saisie.
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
            // Le bandeau/liste n'est visible que si le raccourci a déjà
            // déposé au moins une entrée — l'installation n'a donc pas sa
            // place ici, contrairement à l'entrée Réglages.
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

    // MARK: - Groupement par semaine

    private struct WeekGroup: Identifiable {
        let weekStart: Date
        let entries: [PendingApplePayEntry]
        var id: Date { weekStart }
        var total: Double { entries.reduce(0) { $0 + abs($1.amount) } }
    }

    /// Semaine calendaire (lundi-dimanche, ISO 8601 fixe), la plus récente
    /// d'abord. Appelle EXACTEMENT la même fonction que l'alerte de seuil
    /// (`ApplePayAlertPeriod.week.start(from:)`) plutôt qu'une seconde
    /// implémentation ad hoc — c'était le bug rapporté : cet écran calculait
    /// le début de semaine avec `Calendar.current` (dépendant de la région,
    /// et exécuté dans le process au premier plan) pendant que l'alerte le
    /// calculait séparément depuis l'exécution en arrière-plan de
    /// l'automatisation Raccourcis, deux implémentations qui pouvaient donc
    /// diverger sur la définition même de "cette semaine".
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

    /// "Cette semaine" / "Semaine dernière" quand ça tombe juste, sinon "Semaine
    /// du 25 août" — la date reste un `Text(_, format:)` pour respecter la
    /// locale d'environnement (jamais un `String` littéral concaténé, cf. CLAUDE.md §5).
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

    /// Déposée par le raccourci sans montant connu à l'instant du paiement
    /// (cf. `ImportTransactionApplePayEntityIntent`) — stockée à 0, à corriger
    /// manuellement. `abs` : le montant est toujours négatif une fois connu.
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
        // Écran déjà au premier plan : bump direct, comme `dismiss(_:)`.
        appState.dataRefreshToken = UUID()
    }

    private func dismiss(_ entry: PendingApplePayEntry) {
        repository.updateStatus(id: entry.id, to: .dismissed)
        load()
        // Écran déjà au premier plan (contrairement au dépôt en arrière-plan
        // par l'automatisation Raccourcis) : on peut bumper directement,
        // pas besoin de la notification cross-process.
        appState.dataRefreshToken = UUID()
    }
}
