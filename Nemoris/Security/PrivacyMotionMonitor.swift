import Foundation
import CoreMotion
#if canImport(UIKit)
import UIKit
#endif
import os

// MARK: - PrivacyMotionMonitor
//
// Surveille l'orientation physique du téléphone via CoreMotion. **Le geste
// "retourner face cachée" agit comme un toggle** sur `AppState.amountsHidden` —
// pas un état miroir.
//
// **Comportement** :
//   - User pose le téléphone face cachée (gravity.z passe de < 0.5 à > 0.8)
//     → on TOGGLE `amountsHidden` (1ère fois → masque, 2e fois → réaffiche)
//   - User relève le téléphone (gravity.z repasse < 0.5) → on NE FAIT RIEN
//     (l'état choisi par le user est conservé jusqu'à ce qu'il refasse le geste)
//
// Cette sémantique est plus intuitive que le miroir continu :
//   - Un collègue arrive → tu poses le téléphone face cachée pour cacher les
//     montants. Tu remets face visible normalement pour utiliser l'app,
//     les montants restent masqués (l'écran reste protégé).
//   - Tu réposes face cachée pour les ré-afficher quand t'es seul.
//
// **Hystérésis** : 2 seuils (0.80 entrer, 0.50 sortir) pour détecter proprement
// les transitions sans clignotement quand le téléphone est en transition.
//
// **Énergie** : CMMotionManager à 4 Hz (intervalle 0.25s) — négligeable sur la
// batterie. Suspend en background.
//
// **Activation** : pilotée par `appState.hideAmountsOnFaceDown`. Si OFF, le
// monitor reste en idle (zéro impact).

#if os(macOS)
/// Pas de CoreMotion sur Mac (le geste "poser face cachée" n'a pas de sens
/// pour un ordinateur) : façade no-op, même API.
@MainActor
final class PrivacyMotionMonitor {
    static let shared = PrivacyMotionMonitor()
    private init() {}
    func attach(to appState: AppState) {}
    func syncWithSetting() {}
    func suspend() {}
    func resume() {}
}
#else
@MainActor
final class PrivacyMotionMonitor {

    static let shared = PrivacyMotionMonitor()

    private let manager = CMMotionManager()
    private weak var appState: AppState?

    /// Seuil pour BASCULER en mode masqué — gravity.z > 0.80 ≈ écran à 37° du sol
    /// vers le bas. Assez tolérant pour fonctionner si le téléphone est légèrement
    /// incliné (canapé, poche).
    private let hideThreshold: Double = 0.80

    /// Seuil pour SORTIR du mode masqué — gravity.z < 0.50 ≈ écran à 60° du sol.
    /// Bande morte de 0.30 entre les 2 seuils = hystérésis qui évite le clignotement.
    private let revealThreshold: Double = 0.50

    /// État physique courant du téléphone — `true` quand on est en "face cachée".
    /// On garde la valeur pour détecter les transitions (edges) et déclencher
    /// le toggle uniquement quand on PASSE de "visible" à "cachée".
    /// Initialisé à `false` (= face visible) — au pire on rate le tout 1er
    /// événement si l'user démarre l'app face cachée, négligeable.
    private var isCurrentlyFaceDown: Bool = false

    // MARK: - Public API

    /// À appeler une fois au launch, après que `AppState` soit prêt. Le monitor
    /// se synchronise avec le toggle utilisateur et démarre/arrête en conséquence.
    func attach(to appState: AppState) {
        self.appState = appState
        syncWithSetting()
    }

    /// À appeler quand l'user modifie le toggle `hideAmountsOnFaceDown` dans
    /// Settings — démarre ou arrête le CMMotionManager selon l'état actuel.
    func syncWithSetting() {
        guard let appState else { return }
        if appState.hideAmountsOnFaceDown {
            start()
        } else {
            stop()
            // Si on désactive le réglage, on ne touche PAS à l'état courant —
            // l'user peut vouloir garder les montants masqués manuellement.
        }
    }

    /// À appeler sur scenePhase == .background — arrête les motion updates.
    func suspend() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        Self.log.debug("Motion suspendu (background)")
    }

    /// À appeler sur scenePhase == .active — redémarre si le réglage est activé.
    func resume() {
        syncWithSetting()
    }

    // MARK: - Internals

    private func start() {
        guard manager.isDeviceMotionAvailable else {
            Self.log.warning("Device motion non disponible sur ce device")
            return
        }
        guard !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = 0.25  // 4 Hz, suffisant pour un toggle
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }
            Task { @MainActor in
                self.handle(gravityZ: motion.gravity.z)
            }
        }
        Self.log.debug("Motion monitor démarré")
    }

    private func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        Self.log.debug("Motion monitor arrêté")
    }

    /// Pour iOS : `gravity.z > 0` quand l'écran est tourné vers le bas
    /// (le vecteur gravité pointe dans la même direction que l'axe Z de l'écran).
    /// On utilise des seuils larges + hystérésis pour détecter les transitions.
    ///
    /// **Action** : on TOGGLE `amountsHidden` uniquement à la transition
    /// "visible → cachée". Le retour à "visible" ne fait rien (l'état choisi
    /// par l'user est conservé jusqu'au prochain geste).
    private func handle(gravityZ: Double) {
        guard let appState else { return }

        if !isCurrentlyFaceDown && gravityZ > hideThreshold {
            // Transition : visible → cachée. Toggle l'état d'affichage.
            isCurrentlyFaceDown = true
            appState.amountsHidden.toggle()
            // Tap haptique pour confirmer le geste — utile quand l'écran est
            // posé face cachée et que l'user ne voit pas le changement.
            HapticService.shared.toggle()
        } else if isCurrentlyFaceDown && gravityZ < revealThreshold {
            // Transition : cachée → visible. On NE FAIT RIEN — l'état choisi
            // par l'user via le geste précédent reste actif. Pour le toggler,
            // l'user doit reposer le téléphone face cachée.
            isCurrentlyFaceDown = false
        }
    }

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "PrivacyMotion")
}
#endif
