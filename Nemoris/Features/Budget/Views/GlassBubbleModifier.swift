import SwiftUI
import Charts
import TipKit

struct GlassBubbleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
        }
    }
}
