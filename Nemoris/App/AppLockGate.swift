import SwiftUI

// MARK: - AppLockGate
//
// Lock screen shown as an overlay while the app is not unlocked.
// Startup: authentication auto-triggers after a short delay (200 ms)
// so SwiftUI has time to render the background before iOS presents its
// biometry sheet — otherwise there is a white flash.
//
// If the user cancels or fails, they see a "locked" screen with an
// "Unlock" button they can tap to retry.

struct AppLockGate: View {
    @Binding var isUnlocked: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isAuthenticating = false
    @State private var lastAttemptFailed = false
    @State private var biometryType: AppLockService.BiometryType = .none

    /// Selects the logo asset based on the current colorScheme.
    /// Asset convention: `IconLight` (logo for a light background) and
    /// `IconDark` (logo for a dark background).
    private var logoAssetName: String {
        colorScheme == .dark ? "LogoLight" : "LogoDark"
    }

    var body: some View {
        ZStack {
            // Solid background → hides all underlying content (pre-lock
            // screens must never leak amounts or labels).
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xxxl) {
                Spacer()

                // Nemoris branding — minimal, displays no financial data.
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

                // Primary button — appears AFTER the auto-trigger only on failure.
                // Nothing is shown before a first failed attempt (the iOS sheet
                // already has focus, no need to duplicate it).
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
            // Very short delay so SwiftUI has time to lay down the background
            // before iOS shows the biometry sheet. Without it: white flash on launch.
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
            // Spring animation so the overlay dismissal is smooth.
            withAnimation(.easeOut(duration: 0.25)) {
                isUnlocked = true
            }
        } else {
            HapticService.shared.error()
            lastAttemptFailed = true
        }
    }
}
