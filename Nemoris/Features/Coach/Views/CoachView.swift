import SwiftUI

// MARK: - CoachView
//
// One coach's screen, parameterized by domain — a single code path for both
// "spending" and "investment": they ask the same question of different data,
// and letting them diverge would mean two UIs to maintain.
//
// Non-blocking by construction: the view NEVER waits on an analysis. It
// shows what's persisted, plus a banner while a computation runs. That's
// what lets last week's recommendations stay readable while the new ones
// are being computed.

struct CoachView: View {
    let domain: CoachDomain
    @Environment(CoachStore.self) private var store
    @Environment(AppState.self) private var appState
    // paneDismiss (not \.dismiss): the view is presented via adaptivePane —
    // an iOS sheet OR a macOS pane, and dismissal stays uniform.
    @Environment(\.paneDismiss) private var dismiss

    @State private var selected: CoachRecommendation?
    @State private var showObjectives = false
    /// Disclosure for the model's raw response (diagnosing a failure).
    @State private var showRawResponse = false

    private var analysis: CoachAnalysis { store.analysis(for: domain) }
    private var recommendations: [CoachRecommendation] { store.visibleRecommendations(for: domain) }
    private var isRunning: Bool { store.isRunning(domain) }

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            List {
                if isRunning { runningRow }
                objectivesRow
                if let summary = analysis.profileSummary, !summary.isEmpty { profileRow(summary) }
                if analysis.isError, let message = analysis.message { errorRow(message) }

                if recommendations.isEmpty && !isRunning && !analysis.isError {
                    Section {
                        EmptyStateView(
                            icon: domain.icon,
                            title: "Aucune analyse pour l'instant",
                            message: "Lance une analyse : le coach lit tes données, les met en perspective avec tes objectifs et propose des actions chiffrées."
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(recommendations) { reco in
                        CoachRecommendationRow(reco: reco)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = reco }
                            .rowActions(
                                leading: [
                                    RowAction("Fait", systemImage: "checkmark", tint: AppTheme.Colors.success) {
                                        store.setStatus(.done, for: reco)
                                    }
                                ],
                                trailing: [
                                    RowAction("Pas pour moi", systemImage: "xmark", tint: AppTheme.Colors.textSecondary) {
                                        store.setStatus(.dismissed, for: reco)
                                    }
                                ]
                            )
                            .macGroupedRow(first: reco.id == recommendations.first?.id,
                                           last: reco.id == recommendations.last?.id)
                    }
                }

                if let generatedAt = analysis.generatedAt {
                    Section {
                        footer(generatedAt: generatedAt)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            #if os(macOS)
            .listStyle(.plain)
            .macGroupedListTopGap()
            #endif
            .scrollContentBackground(.hidden)
        }
        .tint(AppTheme.Colors.accent)
        // `paneChrome` rather than a bare `.toolbar`: the view is presented
        // in a pane, and on macOS level 1 it's what publishes the title and
        // buttons into the system bar. A bare `.toolbar` would show no close
        // button there at all.
        .paneChrome(domain.displayName,
                    cancelLabel: "Fermer", onCancel: { dismiss() },
                    confirmLabel: "Analyser", confirmIcon: "arrow.clockwise",
                    confirmDisabled: isRunning) {
            store.refresh(domain)
        }
        .task {
            await store.load()
            // AUTOMATIC re-run if the analysis is stale — asynchronous and
            // non-blocking: the view is already on screen at this point.
            store.refreshIfStale(domain)
        }
        .adaptivePane(item: $selected) { reco in
            CoachRecommendationPane(reco: reco)
        }
        .adaptivePane(isPresented: $showObjectives) {
            CoachObjectivesSheet(domain: domain)
        }
    }

    // MARK: - Status rows

    /// Goals are a LIST ENTRY, not a toolbar icon: they drive the entire
    /// relevance of the recommendations, and a mute target in the toolbar
    /// would say that to no one.
    private var objectivesRow: some View {
        Button { showObjectives = true } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "target")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(domain == .transactions ? "Mes objectifs de dépenses" : "Mes objectifs d'investissement")
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    // Wrap requis : une branche est du texte libre saisi par
                    // l'utilisateur (`String`, jamais traduit — normal),
                    // l'autre un placeholder statique traduisible. Le ternaire
                    // unifie l'expression en `String`, donc `Text(String)`
                    // resterait verbatim sans ce wrap — cf. CLAUDE.md §5. Le
                    // texte libre n'a de toute façon aucune clé correspondante
                    // et s'affiche tel quel (repli normal de LocalizedStringKey).
                    Text(LocalizedStringKey(store.profile(for: domain).hasObjectives
                         ? store.profile(for: domain).objectives
                         : "Dis à CE coach ce que tu veux atteindre — il s'y réfère dans chaque recommandation."))
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .macGroupedRow()
    }

    private var runningRow: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ProgressView().controlSize(.small).tint(AppTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analyse en cours…")
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Tu peux continuer à utiliser l'app, le résultat arrivera tout seul.")
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .macGroupedRow()
    }

    private func profileRow(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("TON PROFIL")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            // `Text(String)`: content GENERATED by the model, already in the
            // user's language — deliberately no localization lookup.
            Text(summary)
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .macGroupedRow()
    }

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.Colors.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("L'analyse n'a pas abouti")
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(message)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            // The model's RAW response — same remedy as the "see the text
            // read" disclosure in document import: a failed extraction is
            // only diagnosable if what the app received can be compared to
            // what it made of it. Without this, "unusable" doesn't
            // distinguish a refusal, an off-topic answer and a truncation.
            //
            // A `Button` + `@State`, NOT a `DisclosureGroup`: nested inside
            // a `List` row, the latter doesn't react to taps. That's exactly
            // why `DocumentAnalysisDiagnosticsSection` already uses this
            // pattern.
            if let raw = analysis.rawResponse, !raw.isEmpty {
                Button {
                    showRawResponse.toggle()
                } label: {
                    Label(showRawResponse
                          ? "Masquer la réponse du modèle"
                          : "Voir la réponse du modèle (\(raw.count) caractères)",
                          systemImage: "text.alignleft")
                        .font(AppTheme.Typography.labelMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.accent)
                .contentShape(Rectangle())

                if showRawResponse {
                    ScrollView {
                        Text(verbatim: raw)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .macGroupedRow()
    }

    private func footer(generatedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("Analysé le ") + Text(generatedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened)))
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            if let backend = analysis.backend {
                Text(verbatim: backend)
                    .font(AppTheme.Typography.labelSmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, AppTheme.Spacing.sm)
    }
}

// MARK: - Row

struct CoachRecommendationRow: View {
    let reco: CoachRecommendation

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: reco.domain.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 38, height: 38)
                .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                if let category = reco.category {
                    Text(verbatim: category.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Text(reco.title)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(3)
                if reco.annualImpact > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        MoneyText(amount: reco.annualImpact,
                                  font: AppTheme.Typography.labelLarge,
                                  color: AppTheme.Colors.success)
                        Text("/an potentiels")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.success.opacity(0.85))
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct CoachRecommendationPane: View {
    let reco: CoachRecommendation
    @Environment(CoachStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(\.paneDismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    if let category = reco.category {
                        Text(verbatim: category.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Text(reco.title)
                        .font(AppTheme.Typography.titleLarge)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(reco.detail)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .padding(.vertical, 2)
            }

            // The rationale is what makes the advice verifiable: without
            // it, the user has to take the model at its word.
            if let rationale = reco.rationale, !rationale.isEmpty {
                Section("Sur quoi le coach s'appuie") {
                    Text(rationale)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Section("Estimations du coach") {
                if reco.annualImpact > 0 {
                    LabeledContent("Impact annuel") {
                        Text(reco.annualImpact, format: .currency(code: "EUR").presentation(.narrow))
                            .foregroundStyle(AppTheme.Colors.success)
                    }
                } else {
                    LabeledContent("Impact annuel", value: "non chiffrable")
                }
                LabeledContent("Faisabilité", value: "\(reco.effort)/5")
                LabeledContent("Confiance", value: "\(Int(reco.confidence * 100)) %")
            }

            Section {
                Button {
                    store.setStatus(.done, for: reco)
                    HapticService.shared.success()
                    appState.postToast(.success, "Marqué comme fait")
                    dismiss()
                } label: {
                    Label("C'est fait", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    store.setStatus(.dismissed, for: reco)
                    HapticService.shared.tap()
                    appState.postToast(.info, "Recommandation écartée")
                    dismiss()
                } label: {
                    Label("Pas pour moi", systemImage: "xmark.circle")
                }
            } footer: {
                Text("Une recommandation écartée ne reviendra pas, même si le coach la repropose lors d'une prochaine analyse.")
                    .font(.caption)
            }
        }
        .nemorisFormStyle()
        .paneChrome("Recommandation", cancelLabel: "Fermer", onCancel: { dismiss() })
    }
}
