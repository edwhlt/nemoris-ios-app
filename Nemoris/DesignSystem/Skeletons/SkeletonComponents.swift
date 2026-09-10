import SwiftUI

// MARK: - Composite skeletons
//
// One composite per real-content layout. Each must match the dimensions and
// spacing of the production component it replaces. Built from primitives only.
// Never copy markup — compose from SkeletonBlock / SkeletonLine / SkeletonCircle.

// MARK: Transaction row (matches TransactionsView.transactionRow)

struct SkeletonTransactionRow: View {
    var body: some View {
        HStack(spacing: 10) {
            SkeletonCircle(size: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    SkeletonLine(width: 140, height: 16)
                    Spacer()
                    SkeletonLine(width: 70, height: 16)
                }
                HStack(spacing: 6) {
                    SkeletonLine(width: 100, height: 11)
                    Spacer()
                    SkeletonBlock(width: 70, height: 18, cornerRadius: 9)
                    SkeletonBlock(width: 50, height: 11, cornerRadius: 4)
                }
            }
            .frame(minHeight: 52)
        }
        .padding(.vertical, 3)
    }
}

// MARK: Tricount entry row (matches TricountEntryRow)
//
// Distinct from `SkeletonTransactionRow`: `TricountEntryRow` has no avatar
// (a small monochrome SF Symbol in a 28pt frame, not a 52pt logo circle) and
// its second line is a plain "payer · date" caption, not a chip row — reusing
// the transaction skeleton here made the loading state visibly jump/resize
// once the real content replaced it (retour d'usage).
struct SkeletonTricountEntryRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonCircle(size: 28)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonLine(width: 150, height: 15)
                SkeletonLine(width: 90, height: 11)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                SkeletonLine(width: 60, height: 15)
                SkeletonLine(width: 40, height: 10)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Reference list row (matches ReferenceDataView tier/category/payment row)

struct SkeletonReferenceListRow: View {
    var hasLogo: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            if hasLogo {
                SkeletonCircle(size: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                SkeletonLine(width: 160, height: 15)
                SkeletonLine(width: 90,  height: 11)
            }
            Spacer()
            SkeletonLine(width: 24, height: 11)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Hero card (matches investments / accounts detail hero)

struct SkeletonHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SkeletonLine(width: 140, height: 11)
            SkeletonBlock(width: 220, height: 36, cornerRadius: 8)
            HStack(spacing: 8) {
                SkeletonLine(width: 70, height: 13)
                SkeletonLine(width: 60, height: 13)
                Spacer()
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}

// MARK: Chart placeholder

struct SkeletonChart: View {
    var height: CGFloat = 200
    var cornerRadius: CGFloat = AppTheme.Radius.md

    var body: some View {
        SkeletonBlock(height: height, cornerRadius: cornerRadius)
    }
}

// MARK: Stat badge (one of 3 in summary cards)

struct SkeletonStatBadge: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            SkeletonCircle(size: 16)
            SkeletonLine(width: 60, height: 16)
            SkeletonLine(width: 50, height: 10)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Donut (allocation card)

struct SkeletonDonut: View {
    var size: CGFloat = 170

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                Circle().fill(AppTheme.Colors.surfaceSecondary)
                Circle().fill(AppTheme.Colors.surface)
                    .frame(width: size * 0.62, height: size * 0.62)
            }
            .frame(width: size, height: size)
            .shimmering()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 8) {
                        SkeletonCircle(size: 10)
                        SkeletonLine(width: 90, height: 12)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Account / group row (matches accountsListCard rows)

struct SkeletonAccountRow: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            SkeletonCircle(size: 8)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonLine(width: 130, height: 14)
                SkeletonLine(width: 90,  height: 11)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                SkeletonLine(width: 80, height: 14)
                SkeletonLine(width: 60, height: 10)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: Position row (matches positionsCard rows)

struct SkeletonPositionRow: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            SkeletonCircle(size: 10)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonLine(width: 110, height: 14)
                SkeletonLine(width: 70,  height: 11)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                SkeletonLine(width: 80, height: 14)
                SkeletonLine(width: 50, height: 11)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: Calendar grid (matches BudgetView.calendarGridContent)

struct SkeletonCalendarGrid: View {
    /// `false` quand un ancêtre rend déjà sa propre ligne de jours de la
    /// semaine — cf. `BudgetView.calendarCarousel`, qui l'affiche UNE fois
    /// au-dessus du carrousel plutôt que par page (les pages voisines pas
    /// encore en cache l'auraient sinon dupliquée).
    var showsHeader: Bool = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
    private let weekdaySymbols = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if showsHeader {
                HStack(spacing: 1) {
                    ForEach(weekdaySymbols, id: \.self) { d in
                        Text(d)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<35, id: \.self) { _ in
                    SkeletonBlock(height: 54, cornerRadius: 8)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        }
    }
}

// MARK: Budget summary bubble (matches BudgetSummaryBubble)

struct SkeletonBudgetBubble: View {
    var body: some View {
        HStack(spacing: 14) {
            SkeletonCircle(size: 16)
            VStack(alignment: .leading, spacing: 3) {
                SkeletonLine(width: 70, height: 11)
                SkeletonBlock(width: 120, height: 4, cornerRadius: 2)
            }
            .frame(width: 120)
            VStack(alignment: .trailing, spacing: 3) {
                SkeletonLine(width: 56, height: 14)
                SkeletonLine(width: 40, height: 10)
            }
            SkeletonCircle(size: 18)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: Capsule())
    }
}

// MARK: Prevision row (matches BudgetView.PrevisionRow)

struct SkeletonPrevisionRow: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            SkeletonCircle(size: 8)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonLine(width: 130, height: 14)
                SkeletonLine(width: 80,  height: 11)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                SkeletonLine(width: 60, height: 14)
                SkeletonLine(width: 40, height: 10)
            }
        }
    }
}

// MARK: Import session row (matches ImportSessionRowCell)

struct SkeletonImportSessionRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SkeletonCircle(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonLine(width: 130, height: 13)
                    SkeletonLine(width: 200, height: 10)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    SkeletonLine(width: 60, height: 13)
                    SkeletonLine(width: 50, height: 10)
                }
            }
            HStack(spacing: 6) {
                SkeletonBlock(width: 80, height: 20, cornerRadius: 10)
                SkeletonBlock(width: 60, height: 20, cornerRadius: 10)
                Spacer()
            }
            HStack(spacing: 6) {
                SkeletonBlock(width: 110, height: 26, cornerRadius: 13)
                Spacer()
                SkeletonCircle(size: 22)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Candidate row (matches enrichment / payee picker)

struct SkeletonCandidateRow: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            SkeletonCircle(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonLine(width: 150, height: 14)
                SkeletonLine(width: 110, height: 11)
            }
            Spacer()
            SkeletonBlock(width: 50, height: 18, cornerRadius: 9)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Paywall product card

struct SkeletonPaywallProductCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SkeletonLine(width: 110, height: 16)
                Spacer()
                SkeletonBlock(width: 80, height: 22, cornerRadius: 11)
            }
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 8) {
                    SkeletonCircle(size: 12)
                    SkeletonLine(width: 170, height: 12)
                }
            }
            SkeletonBlock(height: 44, cornerRadius: 12)
        }
        .padding(16)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }
}

// MARK: Form section (generic, used for any sheet that loads data into a Form)

struct SkeletonFormSection: View {
    var rows: Int = 4

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { i in
                HStack {
                    SkeletonLine(width: 100, height: 13)
                    Spacer()
                    SkeletonLine(width: 140, height: 13)
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
                if i < rows - 1 {
                    Divider().padding(.leading, AppTheme.Spacing.lg)
                }
            }
        }
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }
}

// MARK: - Previews

#Preview("Composites") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            Text("Transaction row").font(.caption).foregroundStyle(.secondary)
            SkeletonTransactionRow()

            Text("Reference row").font(.caption).foregroundStyle(.secondary)
            SkeletonReferenceListRow()

            Text("Hero + chart").font(.caption).foregroundStyle(.secondary)
            SkeletonHero()
            SkeletonChart()

            Text("Donut").font(.caption).foregroundStyle(.secondary)
            SkeletonDonut()

            Text("Calendar").font(.caption).foregroundStyle(.secondary)
            SkeletonCalendarGrid()

            Text("Bubble").font(.caption).foregroundStyle(.secondary)
            SkeletonBudgetBubble()

            Text("Import session row").font(.caption).foregroundStyle(.secondary)
            SkeletonImportSessionRow()

            Text("Paywall card").font(.caption).foregroundStyle(.secondary)
            SkeletonPaywallProductCard()

            Text("Form section").font(.caption).foregroundStyle(.secondary)
            SkeletonFormSection(rows: 4)
        }
        .padding()
    }
    .background(AppTheme.Colors.background)
}
