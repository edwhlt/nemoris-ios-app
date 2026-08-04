import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - HapticService
//
// Service centralisé pour les retours haptiques. Désactivable globalement via
// `appState.hapticsEnabled` (toggle Settings). Utilise les générateurs UIKit
// natifs (UIImpactFeedbackGenerator, UINotificationFeedbackGenerator,
// UISelectionFeedbackGenerator) — pas de dépendance externe.
//
// **Usage typique** :
//   - `HapticService.shared.tap()`         → action discrète (toggle, tap row)
//   - `HapticService.shared.selection()`   → changement de sélection (picker)
//   - `HapticService.shared.success()`     → validation (save form, restore)
//   - `HapticService.shared.warning()`     → confirmation requise (delete)
//   - `HapticService.shared.error()`       → échec (auth refusée, save raté)
//
// **Pourquoi un singleton** : les générateurs UIKit aiment être préparés avant
// l'usage (`prepare()` réveille le moteur Taptic). Le singleton permet de garder
// les générateurs en mémoire et de les pré-warmer une fois.
//
// **Pas de dépendance directe à AppState** dans le service : on lit la prefs
// UserDefaults au moment du fire, ce qui évite un couplage circulaire.

#if os(macOS)
/// Pas de moteur haptique sur Mac (hors trackpad force touch, non pertinent
/// ici) : façade no-op, même API — les ~60 call sites compilent tels quels.
@MainActor
final class HapticService {
    static let shared = HapticService()
    private init() {}
    func tap() {}
    func selection() {}
    func success() {}
    func warning() {}
    func error() {}
    func impact() {}
    func toggle() {}
}
#else
@MainActor
final class HapticService {

    static let shared = HapticService()

    // Pré-instanciés pour éviter la latence du 1er fire. UIKit recommande
    // explicitement `prepare()` ou de garder le générateur vivant.
    private let lightImpact  = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpact  = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    private let selectionGen = UISelectionFeedbackGenerator()

    private init() {
        // Pré-warm tous les générateurs au launch pour éviter le délai du 1er fire.
        lightImpact.prepare()
        mediumImpact.prepare()
        rigidImpact.prepare()
        notification.prepare()
        selectionGen.prepare()
    }

    /// Lecture du toggle global. Source de vérité = UserDefaults pour éviter
    /// le couplage AppState (le service est instancié avant l'AppState peut-être).
    private var enabled: Bool {
        // Default true — c'est l'attente standard d'une app moderne. L'user
        // peut désactiver explicitement dans Settings s'il préfère.
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Tap léger (action discrète). Toggle, like, tap de row.
    func tap() {
        guard enabled else { return }
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Sélection (changement dans un picker, toggle qui CHANGE d'état).
    func selection() {
        guard enabled else { return }
        selectionGen.selectionChanged()
        selectionGen.prepare()
    }

    /// Validation réussie (sauvegarde, restauration, action confirmée).
    func success() {
        guard enabled else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// Avertissement (confirmation requise, action destructive imminente).
    func warning() {
        guard enabled else { return }
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    /// Erreur (auth refusée, save échoué, validation bloquée).
    func error() {
        guard enabled else { return }
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    /// Impact moyen — pour actions à mi-chemin entre tap et success (swipe
    /// completion, drag-drop, etc.). Plus présent qu'un tap mais sans la
    /// connotation "réussi" du success.
    func impact() {
        guard enabled else { return }
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    /// Impact rigide — sec, mécanique. Pour le mode masquage (eye/eye.slash)
    /// ou pour matérialiser un "click" physique d'un toggle.
    func toggle() {
        guard enabled else { return }
        rigidImpact.impactOccurred()
        rigidImpact.prepare()
    }
}
#endif
