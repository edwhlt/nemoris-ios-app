import SwiftUI
import Charts

// MARK: - AXE J — Composants graphiques investissements style Finary
//
// Réutilisables aux 3 niveaux de profondeur : Global (dashboard), Compte, Valeur.
// Respectent strictement la DA Nemoris (AppTheme.Colors / AppTheme.Typography).
//
// Composants exportés :
//   - InvestmentTimeRange (enum)
//   - TimeRangeChips (Picker chips horizontal)
//   - PortfolioEvolutionPoint (data model)
//   - InvestmentHeroCard (big valuation + variation %)
//   - EvolutionChart (line smooth + area gradient + drag-to-inspect)
//   - AllocationDonutChart (SectorMark donut + légende)
//   - InvestmentSparkline (mini line chart pour cards compte)

// MARK: - Time Range

/// Configuration de l'axe X : unité de stride (espacement entre les ticks) +
/// format date pour les labels. Calculé selon la plage temporelle pour que les
/// labels restent lisibles sans se chevaucher.
struct InvestmentChartXAxisConfig {
    let strideUnit: Calendar.Component
    let strideCount: Int
    /// Format d'affichage des labels (ex: "Jun 25", "2024", "12/05").
    let labelFormat: Date.FormatStyle

    static func config(for range: InvestmentTimeRange?, span: TimeInterval) -> InvestmentChartXAxisConfig {
        // span en secondes — utilisé pour `.all` qui n'a pas de startDate.
        let oneDay: TimeInterval = 86_400
        let oneMonth: TimeInterval = 30 * oneDay
        let oneYear: TimeInterval = 365 * oneDay

        // Détermine la "vraie" durée affichée. Pour .all on prend le span réel
        // calculé depuis les points du chart.
        let effective: TimeInterval = {
            guard let range else { return span }
            switch range {
            case .oneDay:     return oneDay
            case .oneWeek:    return 7 * oneDay
            case .oneMonth:   return oneMonth
            case .threeMonth: return 3 * oneMonth
            case .sixMonth:   return 6 * oneMonth
            case .oneYear:    return oneYear
            case .fiveYear:   return 5 * oneYear
            case .tenYear:    return 10 * oneYear
            case .all:        return span
            }
        }()

        if effective <= 2 * oneDay {
            // 1 jour : ticks aux heures
            return .init(
                strideUnit: .hour, strideCount: 6,
                labelFormat: .dateTime.hour()
            )
        } else if effective <= 14 * oneDay {
            // 1-2 semaines : ticks tous les 2 jours, format "JJ MMM"
            return .init(
                strideUnit: .day, strideCount: 2,
                labelFormat: .dateTime.day().month(.abbreviated)
            )
        } else if effective <= 3 * oneMonth {
            // 1-3 mois : ticks hebdomadaires, format "JJ MMM"
            return .init(
                strideUnit: .weekOfYear, strideCount: 1,
                labelFormat: .dateTime.day().month(.abbreviated)
            )
        } else if effective <= oneYear {
            // 6m-1a : ticks mensuels, format "MMM"
            return .init(
                strideUnit: .month, strideCount: 1,
                labelFormat: .dateTime.month(.abbreviated)
            )
        } else if effective <= 3 * oneYear {
            // 1-3 ans : ticks tous les 3 mois, format "MMM yy"
            return .init(
                strideUnit: .month, strideCount: 3,
                labelFormat: .dateTime.month(.abbreviated).year(.twoDigits)
            )
        } else if effective <= 6 * oneYear {
            // 3-6 ans : ticks semestriels, format "MMM yy"
            return .init(
                strideUnit: .month, strideCount: 6,
                labelFormat: .dateTime.month(.abbreviated).year(.twoDigits)
            )
        } else {
            // > 6 ans (10A, Max) : ticks annuels, format "yyyy"
            return .init(
                strideUnit: .year, strideCount: 1,
                labelFormat: .dateTime.year()
            )
        }
    }
}

enum InvestmentTimeRange: String, CaseIterable, Identifiable {
    case oneDay     = "1J"
    case oneWeek    = "1S"
    case oneMonth   = "1M"
    case threeMonth = "3M"
    case sixMonth   = "6M"
    case oneYear    = "1A"
    case fiveYear   = "5A"
    case tenYear    = "10A"
    case all        = "Max"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Sélection des ranges qui font sens étant donnée une date la plus ancienne
    /// dispo (création du compte ou du portefeuille). Ex: compte ouvert il y a
    /// 3 mois → 5A/10A retirées (pas de données à afficher), 6M kept (devient
    /// équivalent à Max sur cette plage). Évite les chips qui ouvrent des
    /// charts vides et donc trompeurs.
    static func availableRanges(since earliestDate: Date) -> [InvestmentTimeRange] {
        let interval = Date().timeIntervalSince(earliestDate)
        let day: TimeInterval = 86_400
        return InvestmentTimeRange.allCases.filter { range in
            switch range {
            case .all:        return true
            case .oneDay:     return interval >= day
            case .oneWeek:    return interval >= 7 * day
            case .oneMonth:   return interval >= 25 * day  // tolérance : 1M dès 25j d'historique
            case .threeMonth: return interval >= 80 * day
            case .sixMonth:   return interval >= 150 * day
            case .oneYear:    return interval >= 300 * day
            case .fiveYear:   return interval >= 4 * 365 * day
            case .tenYear:    return interval >= 8 * 365 * day
            }
        }
    }

    /// Date de début pour le filtre. `nil` = tout l'historique.
    var startDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .oneDay:     return cal.date(byAdding: .day,   value: -1,  to: now)
        case .oneWeek:    return cal.date(byAdding: .day,   value: -7,  to: now)
        case .oneMonth:   return cal.date(byAdding: .month, value: -1,  to: now)
        case .threeMonth: return cal.date(byAdding: .month, value: -3,  to: now)
        case .sixMonth:   return cal.date(byAdding: .month, value: -6,  to: now)
        case .oneYear:    return cal.date(byAdding: .year,  value: -1,  to: now)
        case .fiveYear:   return cal.date(byAdding: .year,  value: -5,  to: now)
        case .tenYear:    return cal.date(byAdding: .year,  value: -10, to: now)
        case .all:        return nil
        }
    }
}

// MARK: - Time Range Chips

/// Sélecteur horizontal de plage temporelle (style Finary/Boursorama).
/// Chips minimalistes avec accent sur la sélection.
struct TimeRangeChips: View {
    @Binding var selection: InvestmentTimeRange
    var ranges: [InvestmentTimeRange] = InvestmentTimeRange.allCases

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ranges) { range in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = range
                    }
                } label: {
                    Text(range.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == range ? AppTheme.Colors.background : AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selection == range ? AppTheme.Colors.accent : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Portfolio Evolution Point

/// Point d'évolution du portefeuille (au niveau global, compte ou position).
/// `value` est la valorisation totale à cette date (qty × close pour les positions sous-jacentes).
struct PortfolioEvolutionPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

extension Array where Element == PortfolioEvolutionPoint {
    /// Assainit une série avant de la donner à Swift Charts.
    ///
    /// ⚠️ Prévention du rendu en "code-barres" : DEUX POINTS LE MÊME JOUR
    /// créent un segment vertical dans une aire/courbe, et une série qui en
    /// contient beaucoup se rend comme un peigne de barres verticales. Le
    /// symptôme est intermittent (« parfois oui, parfois non ») car les
    /// doublons n'apparaissent qu'après une synchro ayant introduit un
    /// horodatage différent pour un jour déjà connu.
    ///
    /// On garantit ici : valeurs finies, un seul point par jour calendaire
    /// (le dernier connu gagne), série triée par date croissante.
    /// Pas de rejet d'outliers ici : sur un portefeuille agrégé une forte
    /// progression est légitime (contrairement au cours d'un titre isolé).
    func sanitizedForChart() -> [PortfolioEvolutionPoint] {
        let cal = Calendar.current
        var byDay: [Date: PortfolioEvolutionPoint] = [:]
        for p in self where p.value.isFinite {
            byDay[cal.startOfDay(for: p.date)] = p
        }
        return byDay.values.sorted { $0.date < $1.date }
    }
}

// MARK: - Investment Hero Card

/// Carte "hero" en haut d'un écran investments (Niveau Global ou Compte).
/// Affiche la valorisation en très gros + variation absolue + variation % sur la plage sélectionnée.
struct InvestmentHeroCard: View {
    let title: String
    let currentValue: Double
    let previousValue: Double?
    let currency: String
    /// Si fourni, label affiché à côté du %, ex : "sur 1 mois"
    var rangeLabel: String? = nil
    /// AXE M : valeur à utiliser COMME BASE pour le calcul de variation, distincte du
    /// `currentValue` cosmétique. Indispensable quand `currentValue` inclut la trésorerie
    /// (qui inflerait artificiellement la perf) — on passe ici la valeur des positions
    /// seules pour avoir une variation cohérente avec `previousValue` (positions seules
    /// aussi). Si nil, fallback sur `currentValue`.
    var variationBasisValue: Double? = nil

    private var basisForVariation: Double { variationBasisValue ?? currentValue }

    private var variationAbs: Double? {
        guard let prev = previousValue else { return nil }
        return basisForVariation - prev
    }

    private var variationPct: Double? {
        guard let prev = previousValue, prev != 0 else { return nil }
        return (basisForVariation - prev) / prev * 100
    }

    private var isPositive: Bool {
        (variationAbs ?? 0) >= 0
    }

    private var variationColor: Color {
        guard let v = variationAbs else { return AppTheme.Colors.textSecondary }
        return v >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label discret (plus de capitales criardes — style Apple Stocks)
            Text(title)
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // Valeur en très gros — passe par MoneyText pour respecter le masquage global
            MoneyText(
                amount: currentValue,
                currency: currency,
                font: AppTheme.Typography.moneyLarge,
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "•• ••• €",
                presentation: .standard
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            // Variation : pastille capsule teintée (vert/rouge) + label de plage à côté.
            if let abs = variationAbs, let pct = variationPct {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text(abs, format: .currency(code: currency))
                            .font(.system(size: 14, weight: .semibold))
                        Text(String(format: "%@%.2f %%", isPositive ? "+" : "", pct))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(variationColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(variationColor.opacity(0.12))
                    )

                    if let rangeLabel {
                        Text(rangeLabel)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Evolution Chart

/// Graphique d'évolution de la valeur (portefeuille / compte / position).
/// Line smooth + area gradient sous + interaction drag pour inspecter un point précis.
struct EvolutionChart: View {
    let points: [PortfolioEvolutionPoint]
    var height: CGFloat = 200
    /// Si fourni, callback notifié quand l'user drag pour inspecter un point.
    var onSelectPoint: ((PortfolioEvolutionPoint?) -> Void)? = nil
    /// Plage temporelle pour adapter la granularité des labels d'axe X.
    /// nil = on calcule depuis les points (utilisé pour les charts sans chip).
    var timeRange: InvestmentTimeRange? = nil

    @State private var selectedDate: Date? = nil

    /// Série effectivement tracée : assainie (un seul point par jour, valeurs
    /// finies, triée). Garde-fou anti "code-barres" — cf. `sanitizedForChart()`.
    /// TOUT le rendu doit passer par ici, jamais par `points` brut.
    private var cleanPoints: [PortfolioEvolutionPoint] { points.sanitizedForChart() }

    /// Span temporel réel couvert par les points (fallback quand timeRange == nil).
    private var pointsSpan: TimeInterval {
        guard let first = cleanPoints.first?.date, let last = cleanPoints.last?.date else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }

    /// Config d'axe X adaptative selon la plage temporelle.
    private var xAxisConfig: InvestmentChartXAxisConfig {
        InvestmentChartXAxisConfig.config(for: timeRange, span: pointsSpan)
    }

    /// Couleur dynamique : vert si tendance haussière sur la plage, rouge sinon.
    private var trendColor: Color {
        guard let first = cleanPoints.first?.value, let last = cleanPoints.last?.value else {
            return AppTheme.Colors.accent
        }
        return last >= first ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    private var selectedPoint: PortfolioEvolutionPoint? {
        guard let selectedDate else { return nil }
        return cleanPoints.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    /// Domaine Y avec un padding visuel pour ne pas coller aux bords.
    private var yDomain: ClosedRange<Double> {
        guard let lo = cleanPoints.map(\.value).min(),
              let hi = cleanPoints.map(\.value).max() else { return 0...1 }
        let span = max(hi - lo, 0.0001)
        let pad = span * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// Valeur minimale réelle des points (pas le min du yDomain qui inclut le padding visuel).
    /// Sert de yStart pour l'AreaMark afin que le remplissage s'arrête au plus bas point
    /// au lieu de descendre jusqu'aux abscisses.
    private var minValue: Double {
        cleanPoints.map(\.value).min() ?? 0
    }

    var body: some View {
        if cleanPoints.isEmpty {
            // Placeholder élégant — pas un EmptyStateView lourd
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("Aucun historique disponible")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: height)
        } else {
            Chart {
                ForEach(cleanPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Valeur", point.value)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

                    // yStart fixé au plus bas point réel (pas yDomain.lowerBound qui
                    // inclut le padding visuel bas) → le remplissage s'arrête au niveau
                    // du minimum de la courbe au lieu de toucher les abscisses.
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", minValue),
                        yEnd: .value("Valeur", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [trendColor.opacity(0.25), trendColor.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }

                // Marqueur sélection : règle verticale + point + tooltip
                if let selectedPoint {
                    RuleMark(x: .value("Sélection", selectedPoint.date))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value("Date", selectedPoint.date),
                        y: .value("Valeur", selectedPoint.value)
                    )
                    .foregroundStyle(trendColor)
                    .symbolSize(60)
                    .annotation(position: .top, alignment: .center, spacing: 6) {
                        VStack(spacing: 2) {
                            Text(selectedPoint.value, format: .currency(code: "EUR"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(selectedPoint.date, format: .dateTime.day().month(.abbreviated).year())
                                .font(.system(size: 10))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                // Ticks + format de label adaptatifs : depending on la plage
                // temporelle (1J → heures, 10A → années) via
                // `InvestmentChartXAxisConfig`. Sans ça, Swift Charts choisit
                // un format auto sans année, ce qui rend illisible un "Max"
                // qui couvre plusieurs années.
                // Plafond de ~5 graduations : `.stride` en produisait des dizaines
                // sur les longues plages (labels superposés + largeur intrinsèque
                // du chart qui explose → vue scrollable horizontalement).
                AxisMarks(position: .bottom, values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: xAxisConfig.labelFormat)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .font(.system(size: 10))
                }
            }
            // Style Apple Stocks : pas de grille Y, juste 2-3 repères de valeur
            // discrets à droite. Le chart respire, la ligne est la vedette.
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel()
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                        .font(.system(size: 10))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        // AXE M : utiliser .gesture avec minimumDistance > 0 + détection
                        // de direction → laisse le ScrollView parent gérer les drags
                        // verticaux (scroll) sans qu'on les intercepte. Avant on avait
                        // minimumDistance: 0 qui capturait tous les touches et faisait
                        // bouger la page pendant le scrub.
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    let dx = abs(value.translation.width)
                                    let dy = abs(value.translation.height)
                                    // Drag à dominance verticale → c'est un scroll, on n'intercepte pas
                                    guard dx > dy else {
                                        if selectedDate != nil {
                                            selectedDate = nil
                                            onSelectPoint?(nil)
                                        }
                                        return
                                    }
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geo[plotFrame].origin
                                    let locationX = value.location.x - origin.x
                                    if let date: Date = proxy.value(atX: locationX) {
                                        selectedDate = date
                                        onSelectPoint?(selectedPoint)
                                    }
                                }
                                .onEnded { _ in
                                    selectedDate = nil
                                    onSelectPoint?(nil)
                                }
                        )
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - Allocation Donut Chart

/// Élément d'allocation pour le donut chart (nom + valeur + couleur stable).
struct AllocationSlice: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let value: Double
}

/// Donut chart d'allocation (par type d'actif ou par compte) + légende.
/// Couleurs dérivées de la palette accent + variantes.
struct AllocationDonutChart: View {
    let slices: [AllocationSlice]
    var currency: String = "EUR"
    var size: CGFloat = 180

    /// Palette stable : accent vert primaire + variations + accentSecondary brun.
    /// On parcourt en boucle pour les > 6 catégories.
    private static let palette: [Color] = [
        AppTheme.Colors.accent,
        AppTheme.Colors.accentSecondary,
        AppTheme.Colors.success,
        AppTheme.Colors.warning,
        Color(hex: "6B9D85"),  // vert plus clair
        Color(hex: "8E5A3B"),  // brun plus clair
        Color(hex: "9A8866"),  // beige
    ]

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    private func color(for index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    private func percentage(of value: Double) -> Double {
        guard total > 0 else { return 0 }
        return value / total * 100
    }

    var body: some View {
        HStack(spacing: 20) {
            // Donut chart
            Chart {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    SectorMark(
                        angle: .value("Valeur", slice.value),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(2)
                    .foregroundStyle(color(for: index))
                }
            }
            .frame(width: size, height: size)
            .overlay {
                // Total au centre du donut
                VStack(spacing: 2) {
                    Text("TOTAL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .tracking(0.5)
                    Text(total, format: .currency(code: currency))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 8)
            }

            // Légende verticale
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: index))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slice.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Text(String(format: "%.1f %%", percentage(of: slice.value)))
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Investment Sparkline

/// Mini line chart pour les cards compte ou row de position.
/// Pas de label, pas d'axes — juste une ligne avec une couleur de tendance.
struct InvestmentSparkline: View {
    let points: [PortfolioEvolutionPoint]
    var height: CGFloat = 32
    var width: CGFloat = 80

    /// Même garde-fou que `EvolutionChart` : série assainie (un point par jour).
    private var cleanPoints: [PortfolioEvolutionPoint] { points.sanitizedForChart() }

    private var trendColor: Color {
        guard let first = cleanPoints.first?.value, let last = cleanPoints.last?.value else {
            return AppTheme.Colors.textSecondary
        }
        return last >= first ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    var body: some View {
        if cleanPoints.count < 2 {
            // Pas assez de données → placeholder discret
            RoundedRectangle(cornerRadius: 2)
                .fill(AppTheme.Colors.textSecondary.opacity(0.1))
                .frame(width: width, height: height)
        } else {
            Chart {
                ForEach(cleanPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Valeur", point.value)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.background(.clear)
            }
            .frame(width: width, height: height)
        }
    }
}
