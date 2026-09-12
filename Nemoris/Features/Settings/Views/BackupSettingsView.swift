import SwiftUI

// MARK: - BackupSettingsView
//
// A Settings view dedicated to local + iCloud snapshots. This is about
// **restore points**: discrete snapshots (automatic daily + manual), a rotation
// of the last 30, an explicit restore with a safety backup taken before overwriting.
//
// This is the basic safety net (free, for everyone): if the iPhone
// is lost/broken/restored/reinstalled, the last iCloud backup can be recovered
// (it survives uninstallation, unlike the local sandbox).
//
// Complementary to `CloudSyncSettingsView` (real-time multi-device CloudKit
// sync). The old `SyncSettingsView` (a continuous one-way export to a folder) was
// removed 2026-07-26 (redundant + its bookmark was lost on uninstall).

struct BackupSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var autoEnabled: Bool = BackupService.shared.autoBackupEnabled
    @State private var lastBackupDate: Date? = BackupService.shared.lastBackupDate
    @State private var iCloudAvailable: Bool = BackupService.shared.isICloudAvailable
    @State private var syncError: String? = BackupService.shared.lastSyncError

    @State private var snapshots: [BackupService.Snapshot] = []
    @State private var isWorking = false
    @State private var snapshotToRestore: BackupService.Snapshot? = nil
    @State private var snapshotToDelete: BackupService.Snapshot? = nil

    var body: some View {
        Form {
            // ── iCloud status ───────────────────────────────────────
            Section {
                HStack {
                    Image(systemName: iCloudAvailable ? "icloud.fill" : "icloud.slash.fill")
                        .foregroundStyle(iCloudAvailable ? AppTheme.Colors.success : AppTheme.Colors.warning)
                    Text(iCloudAvailable ? "iCloud connecté" : "iCloud indisponible")
                        .font(AppTheme.Typography.bodyMedium)
                    Spacer()
                }
                if let err = syncError, !iCloudAvailable {
                    Text(err)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Stockage iCloud")
            } footer: {
                if !iCloudAvailable {
                    Text("Les sauvegardes resteront uniquement sur ce téléphone tant qu'iCloud n'est pas connecté. Activez iCloud Drive dans Réglages pour les protéger en cas de perte ou de réinstallation.")
                        .font(AppTheme.Typography.bodySmall)
                } else {
                    Text("Les sauvegardes sont synchronisées vers iCloud et accessibles depuis l'app Fichiers (Nemoris → Backups).")
                        .font(AppTheme.Typography.bodySmall)
                }
            }

            // ── Auto-backup + last backup ───────────────────────────
            Section {
                Toggle("Sauvegarde automatique quotidienne", isOn: $autoEnabled)
                    .tint(AppTheme.Colors.accent)
                    .onChange(of: autoEnabled) { _, newValue in
                        BackupService.shared.autoBackupEnabled = newValue
                    }

                if let last = lastBackupDate {
                    LabeledContent("Dernière sauvegarde") {
                        Text(last, style: .relative)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                } else {
                    Text("Aucune sauvegarde pour l'instant.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Button {
                    Task { await runBackupNow() }
                } label: {
                    HStack {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Label("Sauvegarder maintenant", systemImage: "arrow.down.doc.fill")
                    }
                }
                .tint(AppTheme.Colors.accent)
                .disabled(isWorking)
            } header: {
                Text("Sauvegarde")
            } footer: {
                Text("Une sauvegarde est créée automatiquement chaque jour au lancement de l'app si plus de 24 h se sont écoulées depuis la précédente. Les 30 plus récentes sont conservées (les plus anciennes sont supprimées automatiquement).")
                    .font(AppTheme.Typography.bodySmall)
            }

            // ── List of available snapshots ─────────────────────────
            Section {
                if snapshots.isEmpty {
                    Text("Aucune sauvegarde disponible.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } else {
                    ForEach(snapshots) { snap in
                        snapshotRow(snap)
                            .rowActions(trailing: [
                                RowAction("Supprimer", systemImage: "trash", role: .destructive) { snapshotToDelete = snap },
                                RowAction("Restaurer", systemImage: "arrow.counterclockwise", tint: AppTheme.Colors.warning) { snapshotToRestore = snap }
                            ], trailingFullSwipe: false)
                    }
                }
            } header: {
                Text("Sauvegardes disponibles (\(snapshots.count))")
            } footer: {
                Text("Glissez vers la gauche pour restaurer ou supprimer. La restauration crée d'abord une sauvegarde de sécurité de la base actuelle.")
                    .font(AppTheme.Typography.bodySmall)
            }
        }
        .nemorisFormStyle()
        .localizedNavigationTitle("Sauvegarde locale & iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .refreshable {
            await refreshAsync()
        }
        .confirmationDialog(
            snapshotToRestore.map { "Restaurer la sauvegarde du \($0.displayName) ?" } ?? "",
            isPresented: Binding(
                get: { snapshotToRestore != nil },
                set: { if !$0 { snapshotToRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restaurer", role: .destructive) {
                if let snap = snapshotToRestore {
                    Task { await runRestore(snap) }
                }
            }
            Button("Annuler", role: .cancel) { snapshotToRestore = nil }
        } message: {
            Text("La base actuelle sera remplacée. Une sauvegarde de sécurité « pre-restore » est créée automatiquement avant écrasement.")
        }
        .confirmationDialog(
            snapshotToDelete.map { "Supprimer la sauvegarde du \($0.displayName) ?" } ?? "",
            isPresented: Binding(
                get: { snapshotToDelete != nil },
                set: { if !$0 { snapshotToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let snap = snapshotToDelete {
                    try? BackupService.shared.deleteSnapshot(snap)
                    reload()
                }
                snapshotToDelete = nil
            }
            Button("Annuler", role: .cancel) { snapshotToDelete = nil }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func snapshotRow(_ snap: BackupService.Snapshot) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: snap.isPreRestore ? "arrow.counterclockwise.circle" : (snap.isICloud ? "icloud" : "iphone"))
                .foregroundStyle(snap.isPreRestore ? AppTheme.Colors.warning : (snap.isICloud ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.displayName)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(snapshotSubtitle(snap))
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
        }
    }

    private func snapshotSubtitle(_ snap: BackupService.Snapshot) -> String {
        let location = snap.isICloud ? "iCloud" : "Local"
        guard snap.isPreRestore else { return "\(snap.sizeLabel) · \(location)" }
        return "\(snap.sizeLabel) · \(location) · Sécurité avant restauration"
    }

    // MARK: - Actions

    private func reload() {
        snapshots = BackupService.shared.listSnapshots()
        lastBackupDate = BackupService.shared.lastBackupDate
        iCloudAvailable = BackupService.shared.isICloudAvailable
        syncError = BackupService.shared.lastSyncError
    }

    private func refreshAsync() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        reload()
    }

    private func runBackupNow() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try BackupService.shared.createSnapshot()
            HapticService.shared.success()
            appState.postToast(.success, "Sauvegarde créée")
        } catch {
            HapticService.shared.error()
            appState.postToast(.error, "Échec : \(error.localizedDescription)")
        }
        reload()
    }

    private func runRestore(_ snap: BackupService.Snapshot) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try BackupService.shared.restore(snapshot: snap)
            // Invalidates every VM — they'll reload from the restored database.
            appState.dataRefreshToken = UUID()
            HapticService.shared.success()
            appState.postToast(.success, "Sauvegarde restaurée — données rechargées")
        } catch {
            HapticService.shared.error()
            appState.postToast(.error, "Restauration échouée : \(error.localizedDescription)")
        }
        snapshotToRestore = nil
        reload()
    }
}
