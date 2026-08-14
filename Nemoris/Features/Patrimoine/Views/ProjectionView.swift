import SwiftUI
import Charts

// MARK: - ProjectionView
//
// Sheet plein écran qui montre la courbe de projection du patrimoine net sur 5 ans
// selon 3 scenarios. Accessible depuis le hero Patrimoine via un bouton "Projeter".
//
// **Lecture de la courbe** :
//   - Ligne verte : net worth projeté (assets − dettes)
//   - Aire en dessous : matérialise visuellement la croissance
//   - 3 scenarios pickables en haut → ligne se met à jour avec animation
//
// **KPIs en bas** :
//   - Patrimoine net dans 5 ans
//   - Gain absolu vs aujourd'hui
//   - Date estimée où le patrimoine net dépasse un palier (100k, 250k, 500k…)

struct ProjectionView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: PatrimoineViewModel

    @State private var scenario: ProjectionScenario = .conservative

    private var monthlyCashFlow: Double {
        ProjectionInputs.netMonthlyCashFlowFromBudget()
    }

    private var points: [ProjectionPoint] {
        ProjectionEngine.project(
            snapshot: viewModel.snapshot,
            totalAssetsLiquid: viewModel.totalAssetsValue,
            realEstateValue: viewModel.totalRealEstateValue,
            loans: viewModel.loans,
            netMonthlyCashFlow: monthlyCashFlow,
            scenario: scenario
        )
    }

    private var endNetWorth: Double {
        points.last?.netWorth ?? 0
    }

    private var startNetWorth: Double {
        points.first?.netWorth ?? 0
    }

    private var gainAbsolute: Double { endNetWorth - startNetWorth }

    private var gainPercent: Double {
        guard abs(startNetWorth) > 0.01 else { return 0 }
        return (endNetWorth - startNetWorth) / abs(startNetWorth) * 100
    }

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    // Picker scenarios — segmented compact
                    scenarioPicker
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.md)

                    // KPI hero — patrimoine net projeté dans 5 ans
                    kpiHero
                        .padding(.horizontal, AppTheme.Spacing.lg)

                    // Chart courbe
                    chartSection
                        .padding(.horizontal, AppTheme.Spacing.lg)

                    // Tableau de bord scenario
                    scenarioDetails
                        .padding(.horizontal, AppTheme.Spacing.lg)

                    // Caveat + alerte contextuelle cashFlow négatif
                    caveatSection
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.bottom, AppTheme.Spacing.xxxl)
                }
            }
            .background(AppTheme.Colors.background)
            .paywallOverlay(for: .patrimoineProjection)
            .paneChrome("Projection 5 ans", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    // MARK: - Picker scenarios

    @ViewBuilder private var scenarioPicker: some View {
        Picker("Scenario", selection: $scenario) {
            ForEach(ProjectionScenario.allCases) { s in
                Text(s.label).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .animation(AppTheme.Animations.springSnappy, value: scenario)
    }

    // MARK: - KPI hero

    @ViewBuilder private var kpiHero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("PATRIMOINE NET DANS 5 ANS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            MoneyText(
                amount: endNetWorth,
                font: .system(size: 38, weight: .bold, design: .default),
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "•• ••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            // Variation vs aujourd'hui
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: gainAbsolute >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                MoneyText(
                    amount: gainAbsolute,
                    font: .system(size: 14, weight: .semibold),
                    color: gainAbsolute >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                )
                if abs(gainPercent) > 0.01 {
                    Text(String(format: "(%@%.1f %%)",
                                gainAbsolute >= 0 ? "+" : "",
                                gainPercent))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(gainAbsolute >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                }
                Text("vs aujourd'hui")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.lg)
        .background(
            LinearGradient(
                colors: [
                    AppTheme.Colors.accent.opacity(0.18),
                    AppTheme.Colors.accent.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.accent.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Chart

    @ViewBuilder private var chartSection: some View {
        // Couleur dynamique — vert si la projection est globalement haussière, terracotta sinon.
        let trendColor: Color = gainAbsolute >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("ÉVOLUTION MOIS PAR MOIS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Net worth", point.netWorth)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Net worth", point.netWorth)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [trendColor.opacity(0.25), trendColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .year)) { _ in
                    AxisValueLabel(format: .dateTime.year(.twoDigits))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    AxisGridLine()
                        .foregroundStyle(AppTheme.Colors.surfaceSecondary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    AxisGridLine()
                        .foregroundStyle(AppTheme.Colors.surfaceSecondary)
                }
            }
            .frame(height: 240)
            .animation(AppTheme.Animations.spring, value: scenario)
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    // MARK: - Caveat éditorial

    /// Caveat sous le chart : explique les hypothèses du moteur ET donne un
    /// message contextuel si le cashFlow est négatif (= mois où l'utilisateur dépense
    /// plus qu'il ne gagne en récurrents → la projection est purement extrapolée
    /// et ne tient pas compte de mécanismes correcteurs réels comme l'agios,
    /// l'augmentation de salaire, etc.).
    @ViewBuilder private var caveatSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if monthlyCashFlow < 0 {
                // Cashflow négatif → la projection part dans le rouge.
                // On l'explique en amont pour éviter le sentiment de bug.
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Flux net mensuel négatif")
                            .font(AppTheme.Typography.titleSmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text("Vos récurrents Budget montrent que vous dépensez plus que vous ne gagnez. La projection est purement mécanique : elle suppose que rien ne change. Dans la vraie vie, vous corrigez (augmenter les revenus, réduire les abonnements, etc.). Servez-vous de cette projection comme d'un signal d'alarme, pas d'une prédiction.")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .background(AppTheme.Colors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            }
            Text("**Hypothèses** : projection en euros constants (pas d'inflation), immobilier maintenu à sa valeur actuelle, prêts amortis selon leur formule contractuelle, aucun nouvel emprunt ni achat majeur. C'est un scénario mécanique, pas une prédiction.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Détails scenario

    @ViewBuilder private var scenarioDetails: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: scenario.systemIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                Text(scenario.label)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            Text(scenario.description)
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Divider()

            // Détails inputs utilisés
            inputRow(label: "Flux net mensuel", value: monthlyCashFlow * scenario.cashFlowMultiplier, color: monthlyCashFlow >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            inputRow(label: "Rendement annuel assets", value: scenario.annualGrowthRate * 100, suffix: " %", color: AppTheme.Colors.accent)
            if let last = points.last {
                inputRow(label: "Dette restante dans 5 ans", value: last.totalLiabilities, color: AppTheme.Colors.danger)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    @ViewBuilder
    private func inputRow(label: String, value: Double, suffix: String = "", color: Color) -> some View {
        HStack {
            Text(label)
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            if suffix.isEmpty {
                MoneyText(amount: value, font: AppTheme.Typography.titleSmall, color: color)
            } else {
                Text(String(format: "%.1f%@", value, suffix))
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(color)
            }
        }
    }
}
