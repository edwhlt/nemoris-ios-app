import Foundation
import CoreMotion
#if canImport(UIKit)
import UIKit
#endif
import os

// MARK: - PrivacyMotionMonitor
//
// Monitors the phone's physical orientation via CoreMotion. **The "flip
// face down" gesture acts as a toggle** on `AppState.amountsHidden` — not a
// mirrored state.
//
// **Behavior**:
//   - User places the phone face down (gravity.z goes from < 0.5 to > 0.8)
//     → TOGGLES `amountsHidden` (1st time → hides, 2nd time → reveals again)
//   - User picks the phone back up (gravity.z drops back below 0.5) → NOTHING
//     HAPPENS (the state the user chose is kept until they repeat the gesture)
//
// This semantics is more intuitive than a continuous mirror:
//   - A colleague walks up → the phone is placed face down to hide amounts.
//     Picking it back up to use the app normally keeps amounts hidden (the
//     screen stays protected).
//   - Placing it face down again reveals them once alone.
//
// **Hysteresis**: 2 thresholds (0.80 to enter, 0.50 to exit) to cleanly
// detect transitions without flickering while the phone is mid-transition.
//
// **Power**: CMMotionManager at 4 Hz (0.25s interval) — negligible battery
// impact. Suspended in background.
//
// **Activation**: driven by `appState.hideAmountsOnFaceDown`. If OFF, the
// monitor stays idle (zero impact).

#if os(macOS)
/// No CoreMotion on Mac (the "place face down" gesture makes no sense for a
/// computer): no-op facade, same API.
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

    /// Threshold to SWITCH into masked mode — gravity.z > 0.80 ≈ screen at
    /// 37° from facing straight down. Tolerant enough to still trigger if
    /// the phone is slightly tilted (couch, pocket).
    private let hideThreshold: Double = 0.80

    /// Threshold to EXIT masked mode — gravity.z < 0.50 ≈ screen at 60° from
    /// facing down. The 0.30 dead band between the 2 thresholds is the
    /// hysteresis that prevents flickering.
    private let revealThreshold: Double = 0.50

    /// Current physical state of the phone — `true` when face down.
    /// Kept around to detect transitions (edges) and trigger the toggle only
    /// when GOING from "visible" to "face down".
    /// Initialized to `false` (= face up) — at worst the very first event is
    /// missed if the user launches the app already face down, negligible.
    private var isCurrentlyFaceDown: Bool = false

    // MARK: - Public API

    /// Call once at launch, after `AppState` is ready. The monitor
    /// synchronizes with the user toggle and starts/stops accordingly.
    func attach(to appState: AppState) {
        self.appState = appState
        syncWithSetting()
    }

    /// Call when the user changes the `hideAmountsOnFaceDown` toggle in
    /// Settings — starts or stops the CMMotionManager based on the current state.
    func syncWithSetting() {
        guard let appState else { return }
        if appState.hideAmountsOnFaceDown {
            start()
        } else {
            stop()
            // Disabling the setting does NOT touch the current state — the
            // user may want to keep amounts masked manually.
        }
    }

    /// Call on scenePhase == .background — stops motion updates.
    func suspend() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        Self.log.debug("Motion suspended (background)")
    }

    /// Call on scenePhase == .active — restarts if the setting is enabled.
    func resume() {
        syncWithSetting()
    }

    // MARK: - Internals

    private func start() {
        guard manager.isDeviceMotionAvailable else {
            Self.log.warning("Device motion not available on this device")
            return
        }
        guard !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = 0.25  // 4 Hz, enough for a toggle
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }
            Task { @MainActor in
                self.handle(gravityZ: motion.gravity.z)
            }
        }
        Self.log.debug("Motion monitor started")
    }

    private func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        Self.log.debug("Motion monitor stopped")
    }

    /// On iOS: `gravity.z > 0` when the screen faces down (the gravity
    /// vector points in the same direction as the screen's Z axis).
    /// Wide thresholds + hysteresis are used to detect transitions cleanly.
    ///
    /// **Action**: `amountsHidden` is TOGGLED only on the "visible → face
    /// down" transition. Returning to "visible" does nothing (the state the
    /// user chose stays active until the next gesture).
    private func handle(gravityZ: Double) {
        guard let appState else { return }

        if !isCurrentlyFaceDown && gravityZ > hideThreshold {
            // Transition: visible → face down. Toggle the display state.
            isCurrentlyFaceDown = true
            appState.amountsHidden.toggle()
            // Haptic tap to confirm the gesture — useful when the screen is
            // face down and the user can't see the change.
            HapticService.shared.toggle()
        } else if isCurrentlyFaceDown && gravityZ < revealThreshold {
            // Transition: face down → visible. NOTHING HAPPENS — the state
            // chosen via the previous gesture stays active. To toggle it,
            // the user must place the phone face down again.
            isCurrentlyFaceDown = false
        }
    }

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "PrivacyMotion")
}
#endif
