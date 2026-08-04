import SwiftUI

// MARK: - Shimmer modifier (single source of truth)
//
// Applies a diagonal gradient sweep across the masked content. One animation
// definition, reused by every skeleton primitive in the app.
//
// Respects `accessibilityReduceMotion` → falls back to a static muted block.
// Colors derived from `AppTheme` so light/dark mode adapt automatically.

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.7

    /// Duration of one sweep across the content.
    static let duration: Double = 1.4
    /// Highlight width relative to the masked content (0 = thin line, 1 = full width).
    static let highlightWidth: CGFloat = 0.45

    func body(content: Content) -> some View {
        if reduceMotion {
            // Static fallback — same base color, no animation.
            content
        } else {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: .clear,                                                       location: 0.0),
                                .init(color: AppTheme.Colors.surface.opacity(0.55),                       location: 0.5),
                                .init(color: .clear,                                                       location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * Shimmer.highlightWidth)
                        .offset(x: phase * geo.size.width)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: Shimmer.duration).repeatForever(autoreverses: false)) {
                        phase = 1.7
                    }
                }
        }
    }
}

extension View {
    /// Apply the unified app shimmer animation to a masked shape.
    /// Already applied by default in `SkeletonBlock`, `SkeletonLine`, `SkeletonCircle`.
    func shimmering() -> some View {
        modifier(Shimmer())
    }
}

// MARK: - Base color

private extension AppTheme.Colors {
    /// Base fill for every skeleton primitive. Adapts light/dark mode automatically.
    static var skeletonBase: Color { surfaceSecondary }
}

// MARK: - Primitives

/// Rectangle skeleton. Defaults to full-width × 14pt height × 6pt corner radius.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.Colors.skeletonBase)
            .frame(width: width, height: height)
            .shimmering()
    }
}

/// Short alias for a single line of placeholder text. Defaults to 14pt (matches `.body` height).
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14

    var body: some View {
        SkeletonBlock(width: width, height: height, cornerRadius: height / 2)
    }
}

/// Circular skeleton — for logos, avatars, dots. `size` is the diameter.
struct SkeletonCircle: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(AppTheme.Colors.skeletonBase)
            .frame(width: size, height: size)
            .shimmering()
    }
}

// MARK: - Previews

#Preview("Primitives") {
    VStack(alignment: .leading, spacing: 16) {
        SkeletonBlock(width: 200, height: 24, cornerRadius: 8)
        SkeletonLine(width: 160)
        SkeletonLine(width: 120, height: 11)
        SkeletonCircle(size: 52)
        HStack(spacing: 12) {
            SkeletonCircle(size: 36)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonLine(width: 140)
                SkeletonLine(width: 90, height: 11)
            }
        }
    }
    .padding()
    .background(AppTheme.Colors.background)
}
