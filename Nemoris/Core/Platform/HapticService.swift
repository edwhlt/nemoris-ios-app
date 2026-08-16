import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - HapticService
//
// Centralized service for haptic feedback. Globally toggleable via
// `appState.hapticsEnabled` (Settings toggle). Uses the native UIKit
// generators (UIImpactFeedbackGenerator, UINotificationFeedbackGenerator,
// UISelectionFeedbackGenerator) — no external dependency.
//
// **Typical usage**:
//   - `HapticService.shared.tap()`         → discreet action (toggle, row tap)
//   - `HapticService.shared.selection()`   → selection change (picker)
//   - `HapticService.shared.success()`     → validation (save form, restore)
//   - `HapticService.shared.warning()`     → confirmation required (delete)
//   - `HapticService.shared.error()`       → failure (auth denied, save failed)
//
// **Why a singleton**: UIKit generators benefit from being prepared before
// use (`prepare()` wakes up the Taptic engine). The singleton keeps the
// generators alive in memory and pre-warms them once.
//
// **No direct dependency on AppState** in the service: the preference is
// read from UserDefaults at fire time, avoiding a circular coupling.

#if os(macOS)
/// No haptic engine on Mac (force-touch trackpad aside, not relevant here):
/// no-op facade with the same API, so the ~60 call sites compile unchanged.
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

    // Pre-instantiated to avoid the latency of the first fire. UIKit
    // explicitly recommends `prepare()` or keeping the generator alive.
    private let lightImpact  = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpact  = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    private let selectionGen = UISelectionFeedbackGenerator()

    private init() {
        // Pre-warms all generators at launch to avoid the delay of the first fire.
        lightImpact.prepare()
        mediumImpact.prepare()
        rigidImpact.prepare()
        notification.prepare()
        selectionGen.prepare()
    }

    /// Reads the global toggle. Source of truth = UserDefaults, to avoid
    /// coupling to AppState (the service may be instantiated before AppState).
    private var enabled: Bool {
        // Default true — the standard expectation for a modern app. The
        // user can explicitly disable it in Settings if preferred.
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Light tap (discreet action). Toggle, like, row tap.
    func tap() {
        guard enabled else { return }
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    /// Selection (change in a picker, a toggle that CHANGES state).
    func selection() {
        guard enabled else { return }
        selectionGen.selectionChanged()
        selectionGen.prepare()
    }

    /// Successful validation (save, restore, confirmed action).
    func success() {
        guard enabled else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// Warning (confirmation required, imminent destructive action).
    func warning() {
        guard enabled else { return }
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    /// Error (auth denied, save failed, validation blocked).
    func error() {
        guard enabled else { return }
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    /// Medium impact — for actions halfway between a tap and a success
    /// (swipe completion, drag-drop, etc.). More noticeable than a tap but
    /// without the "succeeded" connotation of success.
    func impact() {
        guard enabled else { return }
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    /// Rigid impact — sharp, mechanical. For the masking mode (eye/eye.slash)
    /// or to convey the physical "click" of a toggle.
    func toggle() {
        guard enabled else { return }
        rigidImpact.impactOccurred()
        rigidImpact.prepare()
    }
}
#endif
