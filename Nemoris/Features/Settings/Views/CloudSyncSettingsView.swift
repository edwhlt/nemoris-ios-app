import SwiftUI

/// AXE L — Couche L.1 : réglages de la synchronisation iCloud (CloudKit).
///
/// UI minimale de pilotage du `CloudSyncEngine` : toggle opt-in, état du
/// compte iCloud, sync manuelle, dernier sync / erreurs. Le polish (progress
/// détaillée, onboarding, reset du coffre) viendra en Couche L.4.
struct CloudSyncSettingsView: View {

    @State private var status: CloudSyncEngine.Status?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showDisableConfirm = false

    var body: some View {
        // Form (pas List) : écran de réglages statique → boxes arrondies
        // natives sur macOS via nemorisFormStyle(), identique sur iOS.
        // Pas de ZStack+Color (hauteur infinie sur macOS) : fond via .background.
        Form {
            // ── État ──────────────────────────────────────────────────
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 32))
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(AppTheme.Typography.titleMedium)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text("Coffre CloudKit chiffré de bout en bout")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, AppTheme.Spacing.xs)

                if let status {
                    Toggle("Synchronisation iCloud", isOn: Binding(
                        get: { status.enabled },
                        set: { newValue in
                            if newValue { activate() } else { showDisableConfirm = true }
                        }
                    ))
                    .disabled(isWorking || (!status.enabled && !status.accountAvailable))
                }
            } header: {
                Text("État")
            } footer: {
                Text("Vos données sont chiffrées sur l'appareil avant l'envoi. Les clés restent dans votre trousseau iCloud — ni Apple ni personne d'autre ne peut les lire.")
                    .font(.caption)
            }
            .listRowBackground(AppTheme.Colors.surface)

            // ── Actions ───────────────────────────────────────────────
            if status?.enabled == true {
                Section {
                    Button {
                        syncNow()
                    } label: {
                        HStack {
                            Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(isWorking)

                    if let last = status?.lastSyncAt {
                        LabeledContent("Dernier sync", value: Self.displayDate(last))
                            .font(AppTheme.Typography.bodyMedium)
                    }
                    if let pending = status?.pendingCount, pending > 0 {
                        LabeledContent("Modifications en attente", value: "\(pending)")
                            .font(AppTheme.Typography.bodyMedium)
                    }
                } header: {
                    Text("Synchronisation")
                }
                .listRowBackground(AppTheme.Colors.surface)
            }

            // ── Erreurs ───────────────────────────────────────────────
            if let error = errorMessage ?? status?.lastError {
                Section {
                    Label {
                        Text(error)
                            .font(AppTheme.Typography.bodyMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Colors.warning)
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)
            }

            // ── Explications ──────────────────────────────────────────
            Section {
                infoRow(icon: "lock.icloud",
                        title: "Chiffrement de bout en bout",
                        text: "Chaque donnée est stockée dans les champs chiffrés de CloudKit. Le déchiffrement n'est possible que sur vos appareils connectés à votre compte iCloud.")
                infoRow(icon: "iphone.and.arrow.forward",
                        title: "Multi-appareils",
                        text: "iPhone et Mac partagent le même coffre. Les modifications faites sur un appareil apparaissent sur l'autre au prochain sync.")
                infoRow(icon: "externaldrive.fill",
                        title: "Offline-first",
                        text: "L'appareil reste la source de vérité. Sans réseau ou sans iCloud, tout fonctionne — la sync rattrape au retour.")
                infoRow(icon: "key.slash",
                        title: "Jamais synchronisé",
                        text: "Les clés API des exchanges et wallets (live sync) restent dans le trousseau local de chaque appareil, par design.")
            } header: {
                Text("Comment ça marche")
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Synchronisation iCloud")
        .navigationBarTitleDisplayMode(.inline)
        // Rafraîchit en continu tant que l'écran est visible : les accusés de
        // réception CloudKit (qui vident sync_pending) arrivent en tâche de fond
        // APRÈS le retour de sendChanges() — sans ce poll, le compteur resterait
        // figé sur une valeur transitoire. SwiftUI annule la task au disparaître.
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .confirmationDialog(
            "Désactiver la synchronisation ?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Désactiver", role: .destructive) { deactivate() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les données locales et le coffre iCloud sont conservés. Une réactivation refusionnera le tout.")
        }
    }

    // MARK: - Actions

    private func activate() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await CloudSyncEngine.shared.enable()
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
            isWorking = false
        }
    }

    private func deactivate() {
        isWorking = true
        Task {
            await CloudSyncEngine.shared.disable()
            await refresh()
            isWorking = false
        }
    }

    private func syncNow() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await CloudSyncEngine.shared.syncNow()
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
            isWorking = false
        }
    }

    private func refresh() async {
        status = await CloudSyncEngine.shared.status()
    }

    // MARK: - Présentation

    private var statusTitle: String {
        guard let status else { return "Vérification…" }
        if status.enabled && status.isBlocked { return "Activée — action requise" }
        if status.enabled { return "Activée" }
        return status.accountAvailable ? "Désactivée" : "iCloud indisponible"
    }

    private var statusIcon: String {
        guard let status else { return "icloud" }
        if status.enabled && status.isBlocked { return "exclamationmark.icloud.fill" }
        if status.enabled { return "checkmark.icloud.fill" }
        return status.accountAvailable ? "icloud" : "xmark.icloud.fill"
    }

    private var statusColor: Color {
        guard let status else { return AppTheme.Colors.textSecondary }
        if status.enabled && status.isBlocked { return AppTheme.Colors.warning }
        if status.enabled { return AppTheme.Colors.success }
        return status.accountAvailable ? AppTheme.Colors.textSecondary : AppTheme.Colors.warning
    }

    private func infoRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(text)
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private static func displayDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
