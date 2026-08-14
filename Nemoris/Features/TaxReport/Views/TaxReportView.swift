import SwiftUI

// MARK: - TaxReportView
//
// Écran poussé depuis Settings → Avancé → "Rapport fiscal".
// Sélecteur d'année + 3 sections (CTO PV, PEA, Fonciers) avec un récap
// pré-rempli des cases de la déclaration française.
//
// **Export** : bouton "Copier" sur chaque section pour faciliter le report
// dans la déclaration en ligne. Le PDF formaté est un nice-to-have qu'on
// pourra ajouter en V2.

struct TaxReportView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date()) - 1
    @State private var report: TaxReportYear?
    @State private var isComputing: Bool = false

    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current).reversed()
    }

    // Toujours atteinte par PUSH (settingsLink : NavigationLink iOS / pushedSection
    // macOS), jamais en sheet — la NavigationStack + le bouton "Fermer" propres à
    // cet écran doublaient le bouton retour natif fourni par l'appelant. Titre
    // conservé (nécessaire côté iOS, où l'appelant n'en pose pas) mais sans
    // conteneur de navigation propre.
    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    yearPicker
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.md)

                    if let r = report {
                        if r.hasData {
                            ctoSection(report: r)
                            peaSection(report: r)
                            fonciersSection(report: r)
                            disclaimer
                        } else {
                            emptyState
                        }
                    } else if isComputing {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.large).tint(AppTheme.Colors.accent)
                            Spacer()
                        }
                        .padding(.top, AppTheme.Spacing.xxxl)
                    }
                }
                .padding(.bottom, AppTheme.Spacing.xxxl)
            }
        }
        .navigationTitle("Rapport fiscal \(selectedYear.yearLabel)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { compute() }
        .onChange(of: selectedYear) { _, _ in compute() }
    }

    private func compute() {
        isComputing = true
        let year = selectedYear
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                TaxReportEngine.generate(year: year)
            }.value
            await MainActor.run {
                self.report = r
                self.isComputing = false
            }
        }
    }

    // MARK: - Year picker

    @ViewBuilder private var yearPicker: some View {
        HStack {
            Text("Exercice")
                .font(AppTheme.Typography.labelLarge)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Picker("Année", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { y in
                    Text(String(y)).tag(y)
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.Colors.accent)
        }
    }

    // MARK: - CTO section

    @ViewBuilder private func ctoSection(report: TaxReportYear) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeader(
                eyebrow: "PLUS-VALUES MOBILIÈRES (CASE 3VG)",
                trailingButton: report.ctoGains.isEmpty ? nil : "Copier",
                onCopy: { copyCTOSummary(report) }
            )

            if report.ctoGains.isEmpty {
                Text("Aucune cession sur \(report.year.yearLabel). Rien à déclarer en case 3VG.")
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } else {
                // KPI hero : gain net
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GAIN NET DE L'ANNÉE")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        MoneyText(
                            amount: report.ctoNetGain,
                            font: AppTheme.Typography.moneyLarge,
                            color: report.ctoNetGain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                        )
                        Text(report.ctoNetGain >= 0
                             ? "À reporter case **3VG** de la déclaration"
                             : "Moins-value reportable case **3VH** (10 ans)")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(AppTheme.Spacing.lg)
                .background(
                    LinearGradient(
                        colors: [
                            (report.ctoNetGain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger).opacity(0.10),
                            (report.ctoNetGain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger).opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                )

                // Détail par cession (FIFO appliqué)
                ForEach(report.ctoGains) { gain in
                    ctoGainRow(gain)
                }

                Text("Calcul FIFO strict : chaque vente consomme les achats les plus anciens. Les frais d'achat sont déjà intégrés au PRU ; les frais de vente sont déduits du gain.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.85))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    @ViewBuilder private func ctoGainRow(_ gain: CTOGainEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(gain.assetName)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                MoneyText(
                    amount: gain.gain,
                    font: AppTheme.Typography.titleSmall,
                    color: gain.gain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                )
            }
            HStack(spacing: 6) {
                Text(gain.soldAt, format: .dateTime.day().month().year())
                Text("·")
                Text(gain.quantity, format: .number.precision(.fractionLength(0...4))) + Text(" × ") + Text(gain.unitSalePrice, format: .currency(code: "EUR").presentation(.narrow))
                Text("·")
                Text("PRU ") + Text(gain.weightedBuyPrice, format: .currency(code: "EUR").presentation(.narrow))
            }
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private func copyCTOSummary(_ report: TaxReportYear) {
        var text = "Rapport fiscal Nemoris — Année \(report.year)\n"
        text += "Plus-values mobilières (case 3VG) :\n\n"
        for gain in report.ctoGains {
            text += "- \(gain.assetName) (\(gain.ticker)) — \(gain.soldAt.formatted(.dateTime.day().month().year().locale(appState.locale))) — Gain : \(String(format: "%.2f", gain.gain)) €\n"
        }
        text += "\nTOTAL NET : \(String(format: "%.2f", report.ctoNetGain)) €\n"
        UIPasteboard.general.string = text
        HapticService.shared.success()
        appState.postToast(.success, "Récapitulatif CTO copié")
    }

    // MARK: - PEA section

    @ViewBuilder private func peaSection(report: TaxReportYear) -> some View {
        if !report.peaSnapshots.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                sectionHeader(eyebrow: "PEA — SUIVI", trailingButton: nil, onCopy: nil)
                ForEach(report.peaSnapshots) { snap in
                    peaRow(snap)
                }
                Text("Aucune case à remplir pour le PEA si pas de retrait. En cas de retrait, l'imposition dépend de l'âge du plan.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.85))
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
        }
    }

    @ViewBuilder private func peaRow(_ snap: PEASnapshotEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snap.accountName)
                    .font(AppTheme.Typography.titleSmall)
                Spacer()
                MoneyText(
                    amount: snap.currentValue,
                    font: AppTheme.Typography.titleSmall,
                    color: AppTheme.Colors.textPrimary
                )
            }
            Text("Ouvert il y a \(snap.ageYears) an\(snap.ageYears > 1 ? "s" : "")")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(snap.taxStatusLabel)
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(snap.ageYears >= 5 ? AppTheme.Colors.success : AppTheme.Colors.warning)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    // MARK: - Revenus fonciers

    @ViewBuilder private func fonciersSection(report: TaxReportYear) -> some View {
        let income = report.propertyIncome
        if income.totalAmount > 0 {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                sectionHeader(
                    eyebrow: "REVENUS FONCIERS (CASE 4BE / 4BA)",
                    trailingButton: "Copier",
                    onCopy: { copyFonciersSummary(income) }
                )
                VStack(alignment: .leading, spacing: 6) {
                    MoneyText(
                        amount: income.totalAmount,
                        font: AppTheme.Typography.moneyLarge,
                        color: AppTheme.Colors.success
                    )
                    Text("\(income.entriesCount) loyer\(income.entriesCount > 1 ? "s" : "") encaissé\(income.entriesCount > 1 ? "s" : "")")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("**Régime suggéré** : \(income.suggestedRegime)")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .padding(AppTheme.Spacing.lg)
                .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))

                Text("Détection automatique : transactions de revenus dont le libellé, la catégorie ou le tiers contient « loyer ». Vérifiez manuellement avant de reporter.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.85))
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
        }
    }

    private func copyFonciersSummary(_ income: PropertyIncomeSummary) {
        let text = """
        Rapport fiscal Nemoris — Année \(income.year)
        Revenus fonciers : \(String(format: "%.2f", income.totalAmount)) €
        Nombre de loyers : \(income.entriesCount)
        Régime suggéré : \(income.suggestedRegime)
        """
        UIPasteboard.general.string = text
        HapticService.shared.success()
        appState.postToast(.success, "Récapitulatif fonciers copié")
    }

    // MARK: - Empty state + disclaimer

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
            Text("Aucune donnée fiscale pour \(selectedYear.yearLabel)")
                .font(AppTheme.Typography.titleSmall)
            Text("Aucune vente CTO, aucun PEA, aucun loyer détecté sur cette année. Réessayez avec une autre année ou importez vos données.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppTheme.Spacing.xxxl)
    }

    @ViewBuilder private var disclaimer: some View {
        Text("⚠️ **Pré-calcul indicatif uniquement.** Nemoris ne remplace pas un comptable. Vérifiez chaque chiffre avant de le reporter sur votre déclaration. Les cas particuliers (moins-values reportables, abattement durée, crypto, etc.) ne sont pas couverts.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .padding(AppTheme.Spacing.lg)
            .background(AppTheme.Colors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Colors.warning.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, AppTheme.Spacing.lg)
    }

    // MARK: - Header helper

    @ViewBuilder
    private func sectionHeader(eyebrow: String, trailingButton: String?, onCopy: (() -> Void)?) -> some View {
        HStack {
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            if let label = trailingButton, let action = onCopy {
                Button {
                    action()
                } label: {
                    Label(label, systemImage: "doc.on.doc")
                        .font(AppTheme.Typography.labelLarge)
                }
                .tint(AppTheme.Colors.accent)
            }
        }
    }
}
