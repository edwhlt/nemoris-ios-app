import SwiftUI
import Charts
import TipKit

struct CategoryExpensePieChart: View {
    let days: [CalendarDay]
    @Binding var selectedCategory: String?

    private struct Slice: Identifiable {
        let id: String
        let amount: Double
        var label: String { id }
    }

    private var slices: [Slice] {
        var dict: [String: Double] = [:]
        for tx in days.flatMap(\.transactions) where tx.amount < 0 {
            let cat = tx.categoryName.isEmpty ? "Autre" : tx.categoryName
            dict[cat, default: 0] += abs(tx.amount)
        }
        let sorted = dict.map { Slice(id: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
        guard sorted.count > 6 else { return sorted }
        let other = sorted.dropFirst(5).reduce(0) { $0 + $1.amount }
        return Array(sorted.prefix(5)) + [Slice(id: "Autre", amount: other)]
    }

    var body: some View {
        if slices.isEmpty {
            Text("Aucune dépense ce mois")
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else {
            VStack(spacing: 8) {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Montant", slice.amount),
                        innerRadius: .ratio(0.52),
                        angularInset: 2.5
                    )
                    .cornerRadius(5)
                    .foregroundStyle(by: .value("Catégorie", slice.id))
                    .opacity(selectedCategory == nil || selectedCategory == slice.id ? 1.0 : 0.35)
                    .annotation(position: .overlay, alignment: .center) {
                        if selectedCategory == slice.id {
                            Text(slice.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .shadow(radius: 1)
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .center, spacing: 6)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plot = proxy.plotFrame else { return }
                                let frame = geo[plot]
                                let center = CGPoint(x: frame.midX, y: frame.midY)
                                let dx = location.x - center.x
                                let dy = location.y - center.y
                                let radius = sqrt(dx*dx + dy*dy)
                                let outerR = min(frame.width, frame.height) * 0.5
                                let innerR = outerR * 0.52
                                guard radius >= innerR * 0.85 && radius <= outerR * 1.05 else { return }
                                var angle = atan2(dx, -dy)
                                if angle < 0 { angle += 2 * .pi }
                                let total = slices.reduce(0) { $0 + $1.amount }
                                guard total > 0 else { return }
                                var start: Double = 0
                                var found: String? = nil
                                for s in slices {
                                    let frac = s.amount / total
                                    let end = start + frac * 2 * .pi
                                    if angle >= start && angle < end { found = s.id; break }
                                    start = end
                                }
                                if let cat = found {
                                    withAnimation(AppTheme.Animations.easeInOut) {
                                        selectedCategory = (selectedCategory == cat) ? nil : cat
                                    }
                                }
                            }
                    }
                }
                .frame(height: 220)

                if let sel = selectedCategory, let slice = slices.first(where: { $0.id == sel }) {
                    HStack(spacing: 6) {
                        Text(slice.label)
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("·").foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(slice.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                            .font(AppTheme.Typography.labelMedium)
                            .fontWeight(.semibold)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(AppTheme.Animations.easeInOut, value: selectedCategory)
                }
            }
        }
    }
}
