import SwiftUI
import TipKit

struct TricountGroupRow: View {
    let group: TricountGroup
    var isRefreshing: Bool = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.headline)
                Text("\(group.entryCount) entrées · \(group.myName)")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            if isRefreshing {
                ProgressView().padding(.trailing, 4)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(group.fetchedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text(group.currency).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
