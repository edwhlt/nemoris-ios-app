import Foundation
import LocalAuthentication
import os

// MARK: - AppLockService
//
// Verrouillage à l'ouverture de l'app via Face ID / Touch ID / code iOS.
// Pas de code custom Nemoris : on délègue intégralement à LocalAuthentication →
// on hérite de tous les comportements iOS (fallback code, lockout après échecs
// répétés, gestion de l'absence de biometry sur Mac Catalyst, etc.).
//
// **Politique** : `.deviceOwnerAuthentication` (biometry + fallback code iOS).
// Plus accessible que `.deviceOwnerAuthenticationWithBiometrics` (biometry only)
// — un user qui n'arrive plus avec Face ID peut toujours rentrer via son code.
//
// **Quand relock ?** Immédiatement au passage en background (cf. NemorisApp).
// Aucun grace period : pour une app finance, c'est l'attente standard et ça
// évite la surface d'attaque "écran allumé sans surveillance".
//
// **Activation** : l'user doit s'authentifier UNE fois pour activer le toggle
// dans Settings (preuve de propriété du device). Pareil pour le désactiver
// (sinon n'importe qui qui prend le téléphone déverrouillé pourrait désactiver
// le lock à l'insu du propriétaire).

@MainActor
final class AppLockService {

    static let shared = AppLockService()

    // MARK: - UserDefaults-backed state

    /// Verrouillage activé. Si `false`, l'app démarre sans demander d'authentification.
    /// Modifiable uniquement après auth réussie (cf. `setEnabled(_:)`).
    var isLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: "appLockEnabled")
    }

    /// `true` si on doit ré-authentifier à la prochaine entrée foreground.
    /// Mis à `true` au passage `.background` par `NemorisApp` ; remis à `false`
    /// après auth réussie.
    var needsAuthentication: Bool {
        get { UserDefaults.standard.bool(forKey: "appLockNeedsAuth") }
        set { UserDefaults.standard.set(newValue, forKey: "appLockNeedsAuth") }
    }

    // MARK: - Biometry detection

    /// Type de biometry disponible sur le device courant.
    /// Renvoie `.none` si pas de biometry, ou si pas de code iOS configuré (cas
    /// rare mais possible — un user sans aucun code de verrouillage ne peut PAS
    /// activer notre lock, on n'aurait aucun moyen de l'authentifier).
    var biometryType: BiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Si même le code iOS n'est pas configuré, on retourne `.none` ET
            // on force le toggle à false dans `setEnabled` pour éviter un état
            // bloquant.
            Self.log.warning("Auth indisponible : \(error?.localizedDescription ?? "raison inconnue")")
            return .none
        }
        switch context.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID  // iOS 17 Vision Pro
        case .none:    return .passcode // pas de biometry mais code iOS dispo
        @unknown default: return .passcode
        }
    }

    enum BiometryType {
        case none      // ni biometry ni code iOS → lock impossible
        case passcode  // pas de biometry mais code iOS configuré
        case faceID
        case touchID
        case opticID

        var displayName: String {
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

    /// Lance une authentification biometry/code iOS. Bloque le caller jusqu'à
    /// décision user (réussite, échec, annulation). Retourne `true` si auth OK.
    ///
    /// `reason` est affichée par iOS dans la sheet Face ID — DOIT être courte et
    /// claire ("Déverrouiller Nemoris" et pas "Veuillez vous authentifier pour
    /// continuer parce que…").
    func authenticate(reason: String = "Déverrouiller Nemoris") async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Utiliser le code"
        context.localizedCancelTitle = "Annuler"

        // Pré-check : si on ne peut pas évaluer, on échoue tôt sans afficher de
        // sheet (évite un flash UI peu pro).
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            Self.log.error("canEvaluatePolicy false : \(policyError?.localizedDescription ?? "?")")
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if success {
                needsAuthentication = false
                Self.log.info("Auth réussie")
            }
            return success
        } catch {
            Self.log.warning("Auth échouée : \(error.localizedDescription)")
            return false
        }
    }

    /// Active ou désactive le lock. **Demande auth d'abord** pour les 2 sens :
    ///   - Activer : preuve que l'user est bien le propriétaire (sinon n'importe
    ///     qui peut activer et "verrouiller" le téléphone du propriétaire légitime).
    ///   - Désactiver : preuve aussi — sinon une personne qui choperait l'app
    ///     déverrouillée pourrait désactiver le lock à l'insu du propriétaire.
    ///
    /// Retourne `true` si le changement a été appliqué.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        // Cas dégénéré : pas de biometry NI code iOS → on ne peut pas authentifier.
        // Inutile d'essayer (et `evaluatePolicy` renverrait une erreur).
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
        // Quand on active, on considère que l'user vient d'authentifier → pas de
        // re-prompt immédiat. Quand on désactive, on clear le flag aussi.
        needsAuthentication = false
        Self.log.info("Lock \(enabled ? "activé" : "désactivé")")
        return true
    }

    /// Marque l'app comme "doit se ré-authentifier" — appelé au passage en background.
    /// Idempotent : safe à appeler même si lock désactivé (no-op dans ce cas).
    func markNeedsAuthentication() {
        guard isLockEnabled else { return }
        needsAuthentication = true
    }

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "AppLock")
}
