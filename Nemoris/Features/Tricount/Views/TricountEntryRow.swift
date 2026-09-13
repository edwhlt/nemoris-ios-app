import SwiftUI
import TipKit

struct TricountEntryRow: View {
    let entry: TricountEntry
    let myShare: Double?
    let myName: String
    let shareCurrency: String
    var tags: [Tag] = []
    var reimbursementLabel: String? = nil

    private var displayShare: Double? {
        guard let myShare else { return nil }
        let type = entry.typeTransaction.uppercased()
        if type == "TRANSFER" || type == "BALANCE" { return nil }
        // INCOME: income → my share is positive (I receive money)
        if type == "INCOME" { return myShare }
        // NORMAL: an expense → my share is always negative (money spent)
        return -myShare
    }

    /// The total shown with the correct sign per accounting convention:
    /// an expense = negative, income = positive, a transfer = positive
    private var displayTotal: Double {
        let type = entry.typeTransaction.uppercased()
        if type == "NORMAL" { return -entry.total }
        return entry.total
    }

    private var entryTypeLabel: String {
        switch entry.typeTransaction.uppercased() {
        case "NORMAL":   return "Dépense"
        case "INCOME":   return "Revenu"
        case "BALANCE", "TRANSFER": return "Transfert"
        default:         return entry.typeTransaction
        }
    }

    /// A neutral icon — the amount's color already carries the expense/income information.
    private var iconColor: Color { .secondary }

    private var shouldShowLocalAmount: Bool {
        guard let localTotal = entry.localTotal,
              let localCurrency = entry.localCurrency,
              !localCurrency.isEmpty else {
            return false
        }
        return localCurrency.uppercased() != entry.currency.uppercased() || abs(localTotal - entry.total) > 0.005
    }

    private var isPaidByMe: Bool { entry.whoPaid == myName }
    private var isLinked: Bool { entry.linkedTransactionId != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: categoryIcon(entry.category))
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description.isEmpty
                     ? entry.category.lowercased().replacingOccurrences(of: "_", with: " ").capitalized
                     : entry.description)
                    .font(.body)
                    .lineLimit(1)
                // Info line: payer · date · linked
                HStack(spacing: 4) {
                    Text(isPaidByMe ? "Moi" : entry.whoPaid)
                        .font(.caption)
                        .fontWeight(isPaidByMe ? .semibold : .regular)
                        .foregroundStyle(isPaidByMe ? .primary : .secondary)
                        .lineLimit(1)
                    Text("·").font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text(entry.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        .lineLimit(1)
                    if isLinked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.success)
                    }
                }
                if let reimbursementLabel, !reimbursementLabel.isEmpty {
                    Text(reimbursementLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.Colors.warning.opacity(0.13), in: Capsule())
                        .foregroundStyle(AppTheme.Colors.warning)
                        .lineLimit(1)
                }
                // Tags chips
                if !tags.isEmpty {
                    let chips = HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            Text(tag.name)
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tag.displayColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(tag.displayColor)
                        }
                    }
                    // ⚠️ macOS: NEVER a ScrollView inside a List row. A scroll
                    // (horizontal here, for the chips) measured inside an
                    // NSTableView cell triggers a "reentrant operation in NSTableView
                    // delegate" → a layout loop → the window bar and pushed
                    // views' back button vibrate CONSTANTLY. On Mac
                    // the chips are rendered in a clipped HStack (a wide row width
                    // on desktop, most fit). iOS keeps the touch scroll.
                    #if os(macOS)
                    chips
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                    #else
                    ScrollView(.horizontal, showsIndicators: false) { chips }
                    #endif
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(displayTotal, format: .currency(code: entry.currency))
                    .font(.subheadline).bold()
                    .foregroundStyle(displayTotal < 0 ? AppTheme.Colors.danger : (displayTotal > 0 ? AppTheme.Colors.success : AppTheme.Colors.textPrimary))
                if shouldShowLocalAmount,
                   let localTotal = entry.localTotal,
                   let localCurrency = entry.localCurrency {
                    let displayLocalTotal = entry.typeTransaction.uppercased() == "NORMAL" ? -localTotal : localTotal
                    Text(displayLocalTotal, format: .currency(code: localCurrency))
                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                }
                if let share = displayShare, abs(share) > 0.005 {
                    (Text("Part : ") + Text(share, format: .currency(code: shareCurrency)))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func categoryIcon(_ cat: String) -> String {
        switch cat.uppercased() {
        case "FOOD_AND_DRINK": return "fork.knife"
        case "GROCERIES": return "cart"
        case "TRANSPORTATION": return "car"
        case "ACCOMMODATION": return "house"
        case "ENTERTAINMENT": return "ticket"
        case "HEALTH": return "heart"
        case "SHOPPING": return "bag"
        case "BALANCE": return "arrow.left.arrow.right"
        case "INCOME": return "plus.circle"
        default: return "creditcard"
        }
    }
}
