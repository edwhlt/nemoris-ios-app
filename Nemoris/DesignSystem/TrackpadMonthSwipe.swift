import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Two-finger trackpad swipe (macOS) → previous/next callback. Used by
/// `BudgetView` to change month the same way a horizontal swipe does on iOS
/// (there, `TabView(.page)` gives it for free — macOS has no equivalent
/// gesture on a plain view, and `PageTabViewStyle` isn't supported on macOS
/// at all, cf. the comment on `BudgetView.calendarCarousel`).
///
/// Deliberately a **local event monitor**, not an `NSViewRepresentable`
/// overlay: an overlay `NSView` placed over the calendar to catch
/// `scrollWheel` would also become the hit-test target for mouse CLICKS at
/// that location (`hitTest` doesn't know the event type in advance), which
/// would break taps on the day cells underneath. A local monitor receives a
/// copy of every scroll-wheel event system-wide while installed and always
/// returns the event unmodified — the real `ScrollView` still scrolls
/// normally, this is purely a spy on the same events, never an interceptor.
private struct TrackpadMonthSwipeModifier: ViewModifier {
    let onSwipeLeft: () -> Void   // next month (content "moves left")
    let onSwipeRight: () -> Void  // previous month

    @State private var monitor: Any?
    @State private var accumulatedX: CGFloat = 0
    @State private var accumulatedY: CGFloat = 0

    /// Horizontal distance (points) a two-finger swipe must cover before
    /// it's treated as "change month" rather than incidental sideways drift
    /// during a vertical scroll of the page below the calendar.
    private static let threshold: CGFloat = 80
    /// How much more horizontal than vertical movement the gesture needs —
    /// rejects a vertical scroll that wobbles slightly sideways.
    private static let dominanceRatio: CGFloat = 2.5

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handle(event)
            return event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Only real trackpad/Magic Mouse gestures carry precise deltas — a
        // classic scroll wheel's much coarser single-click delta would
        // otherwise trip the threshold on one notch.
        guard event.hasPreciseScrollingDeltas else { return }
        switch event.phase {
        case .began:
            accumulatedX = 0
            accumulatedY = 0
        case .changed:
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
        case .ended, .cancelled:
            defer { accumulatedX = 0; accumulatedY = 0 }
            guard abs(accumulatedX) > Self.threshold,
                  abs(accumulatedX) > abs(accumulatedY) * Self.dominanceRatio else { return }
            // Défilement naturel macOS (le contenu suit le doigt) : deux
            // doigts vers la GAUCHE ⇒ deltaX négatif ⇒ le contenu "suivant"
            // apparaît, comme un swipe gauche sur iOS.
            if accumulatedX < 0 {
                onSwipeLeft()
            } else {
                onSwipeRight()
            }
        default:
            break
        }
    }
}
#endif

extension View {
    /// Two-finger trackpad swipe → previous/next month, macOS only. No-op on
    /// iOS (which already has this via `TabView(.page)`'s native swipe).
    @ViewBuilder
    func trackpadMonthSwipe(onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) -> some View {
        #if os(macOS)
        modifier(TrackpadMonthSwipeModifier(onSwipeLeft: onNext, onSwipeRight: onPrevious))
        #else
        self
        #endif
    }
}
