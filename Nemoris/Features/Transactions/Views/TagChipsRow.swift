import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TagChipsRow: View {
    let tags: [Tag]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption).fontWeight(.semibold)
                        Button { onRemove(tag.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AppTheme.Colors.accentSecondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                }
            }
        }
    }
}
