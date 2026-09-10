import Foundation
import LocalAuthentication
import os

// MARK: - AppLockService
//
// Locks the app on open via Face ID / Touch ID / iOS passcode.
// No custom Nemoris code: authentication is delegated entirely to
// LocalAuthentication, inheriting all of iOS's behaviors (passcode fallback,
// lockout after repeated failures, handling the absence of biometry on Mac
// Catalyst, etc.).
//
// **Policy**: `.deviceOwnerAuthentication` (biometry + iOS passcode
// fallback). More accessible than `.deviceOwnerAuthenticationWithBiometrics`
// (biometry only) — a user who can no longer get in with Face ID can still
// enter via their passcode.
//
// **When to relock?** Immediately on backgrounding (see NemorisApp). No
// grace period: for a finance app this is the standard expectation, and it
// avoids the attack surface of an unlocked, unattended screen.
//
// **Activation**: the user must authenticate ONCE to turn the toggle on in
// Settings (proof of device ownership). Same to turn it off (otherwise
// anyone who picks up the unlocked phone could disable the lock without the
// owner's knowledge).

@MainActor
final class AppLockService {

    static let shared = AppLockService()

    // MARK: - UserDefaults-backed state

    /// Whether the lock is enabled. If `false`, the app starts without
    /// requesting authentication. Only mutable after a successful auth
    /// (see `setEnabled(_:)`).
    var isLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: "appLockEnabled")
    }

    /// `true` if re-authentication is required on the next foreground entry.
    /// Set to `true` on `.background` by `NemorisApp`; reset to `false`
    /// after a successful auth.
    var needsAuthentication: Bool {
        get { UserDefaults.standard.bool(forKey: "appLockNeedsAuth") }
        set { UserDefaults.standard.set(newValue, forKey: "appLockNeedsAuth") }
    }

    // MARK: - Biometry detection

    /// Biometry type available on the current device.
    /// Returns `.none` if there's no biometry, or no iOS passcode configured
    /// (a rare but possible case — a user with no lock method at all cannot
    /// enable our lock, since there would be no way to authenticate them).
    var biometryType: BiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // If even the iOS passcode isn't configured, `.none` is returned
            // AND `setEnabled` forces the toggle back to false to avoid a
            // blocking state.
            Self.log.warning("Auth unavailable: \(error?.localizedDescription ?? "unknown reason")")
            return .none
        }
        switch context.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID  // iOS 17 Vision Pro
        case .none:    return .passcode // no biometry but an iOS passcode is available
        @unknown default: return .passcode
        }
    }

    enum BiometryType {
        case none      // neither biometry nor iOS passcode → locking is impossible
        case passcode  // no biometry but an iOS passcode is configured
        case faceID
        case touchID
        case opticID

        var displayName: LocalizedStringResource {
            switch self {
            case .none:     return "Indisponible"
            case .passcode: return "Code d'accès"
            case .faceID:   return "Face ID"
            case .touchID:  return "Touch ID"
            case .opticID:  return "Optic ID"
            }
        }

        var systemIcon: String {
            switch self {
            case .none:     return "lock.slash"
            case .passcode: return "key.fill"
            case .faceID:   return "faceid"
            case .touchID:  return "touchid"
            case .opticID:  return "eye.fill"
            }
        }

        var canLock: Bool { self != .none }
    }

    // MARK: - Public API

    /// Starts a biometry/iOS-passcode authentication. Blocks the caller
    /// until a product decision is reached (success, failure, cancellation).
    /// Returns `true` if auth succeeded.
    ///
    /// `reason` is displayed by iOS in the Face ID sheet — it MUST be short
    /// and clear ("Unlock Nemoris", not "Please authenticate to continue
    /// because…").
    func authenticate(reason: String = "Déverrouiller Nemoris") async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Utiliser le code"
        context.localizedCancelTitle = "Annuler"

        // Pre-check: if evaluation isn't possible, fail early without
        // showing a sheet (avoids an unpolished UI flash).
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            Self.log.error("canEvaluatePolicy false: \(policyError?.localizedDescription ?? "?")")
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if success {
                needsAuthentication = false
                Self.log.info("Auth succeeded")
            }
            return success
        } catch {
            Self.log.warning("Auth failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Enables or disables the lock. **Requests auth first** in both
    /// directions:
    ///   - Enabling: proof that the user is really the owner (otherwise
    ///     anyone could enable it and "lock" the legitimate owner's phone).
    ///   - Disabling: proof as well — otherwise someone who got hold of the
    ///     unlocked app could disable the lock without the owner's knowledge.
    ///
    /// Returns `true` if the change was applied.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        // Degenerate case: no biometry AND no iOS passcode → authentication
        // is impossible. No point trying (`evaluatePolicy` would just error).
        guard biometryType.canLock else {
            UserDefaults.standard.set(false, forKey: "appLockEnabled")
            return false
        }

        let reason = enabled
            ? "Activer le verrouillage Nemoris"
            : "Désactiver le verrouillage Nemoris"
        let success = await authenticate(reason: reason)
        guard success else { return false }

        UserDefaults.standard.set(enabled, forKey: "appLockEnabled")
        // When enabling, the user is considered to have just authenticated →
        // no immediate re-prompt. When disabling, the flag is cleared too.
        needsAuthentication = false
        Self.log.info("Lock \(enabled ? "enabled" : "disabled")")
        return true
    }

    /// Marks the app as "needs to re-authenticate" — called on backgrounding.
    /// Idempotent: safe to call even if the lock is disabled (no-op in that case).
    func markNeedsAuthentication() {
        guard isLockEnabled else { return }
        needsAuthentication = true
    }

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "AppLock")
}
