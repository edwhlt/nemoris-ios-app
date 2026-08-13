import SwiftUI

// MARK: - AppLockGate
//
// Écran de verrouillage affiché en overlay tant que l'app n'est pas déverrouillée.
// Démarrage : auto-trigger de l'authentification après un court délai (200 ms)
// pour laisser SwiftUI rendre le fond avant que iOS pose sa sheet biometry —
// évite un flash blanc disgracieux.
//
// Si l'utilisateur annule ou échoue, il voit un écran "verrouillé" avec un bouton
// "Déverrouiller" qu'il peut retaper pour relancer.

struct AppLockGate: View {
    @Binding var isUnlocked: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isAuthenticating = false
    @State private var lastAttemptFailed = false
    @State private var biometryType: AppLockService.BiometryType = .none

    /// Sélectionne l'asset logo en fonction du colorScheme courant.
    /// Convention assets : `IconLight` (logo pour fond clair) et
    /// `IconDark` (logo pour fond sombre).
    private var logoAssetName: String {
        colorScheme == .dark ? "LogoLight" : "LogoDark"
    }

    var body: some View {
        ZStack {
            // Fond plein → masque tout le contenu en arrière-plan (les sceens
            // pre-lock ne doivent JAMAIS leak des montants ou des libellés).
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xxxl) {
                Spacer()

                // Marque Nemoris — minimaliste, sans afficher de données financières.
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                        .fill(AppTheme.Colors.accent.opacity(0.10))
                        .frame(width: 96, height: 96)
                    Image(logoAssetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
                }

                VStack(spacing: AppTheme.Spacing.sm) {
                    Text("Nemoris")
                        .font(AppTheme.Typography.displaySmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Verrouillé")
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                // Bouton principal — apparaît APRÈS l'auto-trigger si échec.
                // Tant qu'on n'a pas échoué une fois on n'affiche rien (la sheet
                // iOS prend le focus, pas la peine de doubler).
                if lastAttemptFailed {
                    Button {
                        Task { await authenticate() }
                    } label: {
                        Label(
                            "Déverrouiller avec \(biometryType.displayName)",
                            systemImage: biometryType.systemIcon
                        )
                        .font(AppTheme.Typography.titleSmall)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .foregroundStyle(.white)
                        .background(AppTheme.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, AppTheme.Spacing.xxxl)
                    .disabled(isAuthenticating)
                } else if isAuthenticating {
                    ProgressView()
                        .tint(AppTheme.Colors.accent)
                        .controlSize(.large)
                }

                Spacer().frame(height: AppTheme.Spacing.xxxl)
            }
        }
        .task {
            biometryType = AppLockService.shared.biometryType
            // Délai très court pour que SwiftUI ait le temps de poser le fond avant
            // que iOS affiche la sheet biometry. Sans ça : flash blanc au launch.
            try? await Task.sleep(nanoseconds: 200_000_000)
            await authenticate()
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        defer { isAuthenticating = false }
        let success = await AppLockService.shared.authenticate(reason: "Déverrouiller Nemoris")
        if success {
            HapticService.shared.success()
            // Animation spring pour que la disparition de l'overlay soit douce.
            withAnimation(.easeOut(duration: 0.25)) {
                isUnlocked = true
            }
        } else {
            HapticService.shared.error()
            lastAttemptFailed = true
        }
    }
}
