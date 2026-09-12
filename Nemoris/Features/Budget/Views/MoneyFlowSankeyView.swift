import SwiftUI
import Charts
import TipKit

struct MoneyFlowSankeyView: View {
    let days: [CalendarDay]

    private struct SankeyNode: Identifiable {
        let id = UUID()
        let label: String
        let amount: Double
        let color: Color
    }

    private struct NodeLayout: Identifiable {
        let node: SankeyNode
        let y: CGFloat
        let height: CGFloat
        var id: UUID { node.id }
        var color: Color { node.color }
    }

    private static let incomeColors: [Color] = [
        Color(hex: "34D399"), Color(hex: "10B981"), Color(hex: "6EE7B7"),
        Color(hex: "059669"), Color(hex: "A7F3D0")
    ]
    private static let expenseColors: [Color] = [
        Color(hex: "5EA1FF"), Color(hex: "FBBF24"), Color(hex: "F87171"),
        Color(hex: "7B61FF"), Color(hex: "FB923C"), Color(hex: "E879F9")
    ]

    private var incomeNodes: [SankeyNode] {
        var dict: [String: Double] = [:]
        for tx in days.flatMap(\.transactions) where tx.amount > 0 {
            let cat = tx.categoryName.isEmpty ? "Revenu" : tx.categoryName
            dict[cat, default: 0] += tx.amount
        }
        return dict.sorted { $0.value > $1.value }.prefix(4).enumerated()
            .map { idx, pair in SankeyNode(label: pair.key, amount: pair.value, color: Self.incomeColors[idx]) }
    }

    private var expenseNodes: [SankeyNode] {
        var dict: [String: Double] = [:]
        for tx in days.flatMap(\.transactions) where tx.amount < 0 {
            let cat = tx.categoryName.isEmpty ? "Autre" : tx.categoryName
            dict[cat, default: 0] += abs(tx.amount)
        }
        let sorted = dict.sorted { $0.value > $1.value }
        var nodes = sorted.prefix(4).enumerated()
            .map { idx, pair in SankeyNode(label: pair.key, amount: pair.value, color: Self.expenseColors[idx]) }
        if sorted.count > 4 {
            let other = sorted.dropFirst(4).reduce(0) { $0 + $1.value }
            nodes.append(SankeyNode(label: "Autre", amount: other, color: Color(.systemGray)))
        }
        return nodes
    }

    private var totalIncome: Double { incomeNodes.reduce(0) { $0 + $1.amount } }
    private var totalExpenses: Double { expenseNodes.reduce(0) { $0 + $1.amount } }

    private func makeLayout(nodes: [SankeyNode], scale: Double, height: CGFloat, gap: CGFloat, minHeight: CGFloat = 4) -> [NodeLayout] {
        guard scale > 0, !nodes.isEmpty else { return [] }
        let totalGap = gap * CGFloat(max(nodes.count - 1, 0))
        let usable = height - totalGap
        var y: CGFloat = 0
        return nodes.map { node in
            // A floor raised above the purely visual minimum (4pt): without
            // it, a small category got a band so thin that its 2-line label
            // + amount overlapped the neighboring node — the real cause
            // of the "squashed" look on a narrow container, not just
            // `labelW`'s width.
            let h = max((node.amount / scale) * usable, minHeight)
            let ln = NodeLayout(node: node, y: y, height: h)
            y += h + gap
            return ln
        }
    }

    var body: some View {
        if incomeNodes.isEmpty && expenseNodes.isEmpty {
            Text("Aucune donnée ce mois")
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            let extraRow = totalIncome > totalExpenses ? 1 : 0
            let chartH = CGFloat(max(incomeNodes.count, expenseNodes.count + extraRow)) * 60 + 20
            GeometryReader { geo in
                let nodeW: CGFloat = 10
                // Label width proportional to the available space (instead of a
                // fixed value): on a narrow container (a macOS pane, mobile
                // portrait), 90pt on each side squeezed the central flow to
                // almost nothing. Bounded to stay readable at both extremes.
                let labelW: CGFloat = min(max(geo.size.width * 0.24, 58), 92)
                let gap: CGFloat = 5
                let leftX: CGFloat = labelW + 4
                let rightX: CGFloat = geo.size.width - labelW - 4
                let midX: CGFloat = (leftX + rightX) * 0.5
                let h = geo.size.height
                let maxT = max(totalIncome, totalExpenses, 1)
                let leftLayout  = makeLayout(nodes: incomeNodes,  scale: maxT, height: h, gap: gap, minHeight: 28)
                let rightLayout = makeLayout(nodes: expenseNodes, scale: maxT, height: h, gap: gap, minHeight: 28)
                let savingsAmount = totalIncome - totalExpenses
                let savingsH: CGFloat = savingsAmount > 0
                    ? max((savingsAmount / maxT) * h, 4) : 0
                let savingsY: CGFloat = rightLayout.last.map { $0.y + $0.height + gap } ?? 0

                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        // Flow ribbons from left income total → each right expense node
                        var srcY: CGFloat = 0
                        for rn in rightLayout {
                            var p = Path()
                            p.move(to:    CGPoint(x: leftX + nodeW, y: srcY))
                            p.addCurve(to: CGPoint(x: rightX - nodeW, y: rn.y),
                                       control1: CGPoint(x: midX, y: srcY),
                                       control2: CGPoint(x: midX, y: rn.y))
                            p.addLine(to:  CGPoint(x: rightX - nodeW, y: rn.y + rn.height))
                            p.addCurve(to: CGPoint(x: leftX + nodeW, y: srcY + rn.height),
                                       control1: CGPoint(x: midX, y: rn.y + rn.height),
                                       control2: CGPoint(x: midX, y: srcY + rn.height))
                            p.closeSubpath()
                            ctx.fill(p, with: .color(rn.color.opacity(0.15)))
                            srcY += rn.height + gap
                        }
                        // Savings flow ribbon
                        if savingsH > 0 {
                            var p = Path()
                            p.move(to:    CGPoint(x: leftX + nodeW, y: srcY))
                            p.addCurve(to: CGPoint(x: rightX - nodeW, y: savingsY),
                                       control1: CGPoint(x: midX, y: srcY),
                                       control2: CGPoint(x: midX, y: savingsY))
                            p.addLine(to:  CGPoint(x: rightX - nodeW, y: savingsY + savingsH))
                            p.addCurve(to: CGPoint(x: leftX + nodeW, y: srcY + savingsH),
                                       control1: CGPoint(x: midX, y: savingsY + savingsH),
                                       control2: CGPoint(x: midX, y: srcY + savingsH))
                            p.closeSubpath()
                            ctx.fill(p, with: .color(Color(hex: "34D399").opacity(0.12)))
                        }
                        // Left income bars
                        for ln in leftLayout {
                            ctx.fill(Path(CGRect(x: leftX, y: ln.y, width: nodeW, height: ln.height)),
                                     with: .color(ln.color))
                        }
                        // Right expense bars
                        for rn in rightLayout {
                            ctx.fill(Path(CGRect(x: rightX - nodeW, y: rn.y, width: nodeW, height: rn.height)),
                                     with: .color(rn.color))
                        }
                        // Savings bar
                        if savingsH > 0 {
                            ctx.fill(Path(CGRect(x: rightX - nodeW, y: savingsY, width: nodeW, height: savingsH)),
                                     with: .color(Color(hex: "34D399").opacity(0.55)))
                        }
                    }

                    // Left labels (income) — right-aligned before bar
                    ForEach(leftLayout) { ln in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(ln.node.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(ln.color)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.trailing)
                            Text(ln.node.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: labelW, height: max(ln.height, 28), alignment: .trailing)
                        .offset(x: 0, y: ln.y)
                    }

                    // Right labels (expenses) — left-aligned after bar
                    ForEach(rightLayout) { rn in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rn.node.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(rn.color)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.leading)
                            Text(rn.node.amount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: labelW, height: max(rn.height, 28), alignment: .leading)
                        .offset(x: rightX + 4, y: rn.y)
                    }

                    // Savings label
                    if savingsH > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Épargne")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(hex: "34D399"))
                                .lineLimit(1)
                            Text(savingsAmount, format: .currency(code: "EUR").precision(.fractionLength(0)))
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: labelW, height: max(savingsH, 28), alignment: .leading)
                        .offset(x: rightX + 4, y: savingsY)
                    }
                }
            }
            .frame(height: chartH)
        }
    }
}
