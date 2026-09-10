import SwiftUI

/// Détail en lecture seule d'un candidat détecté par `RecurringDetector` :
/// justifie pourquoi les 4 critères (tiers/fréquence/montant/date) sont
/// réunis, avec les valeurs réellement observées et les tolérances
/// réellement utilisées par le moteur (jamais des nombres recopiés à la
/// main — `RecurringDetector.amountTolerance`/`gapWindow`/`dateTolerance`
/// sont la source unique, cf. RecurringDetector.swift).
struct DetectionCandidateDetailPane: View {
    let candidate: DetectionCandidate
    /// Motif déjà suivi correspondant à ce candidat (même payee/nom), s'il en
    /// existe un — actif ou non. Non-nil ⇒ confirmer créerait un doublon, la
    /// vue le signale au lieu de le permettre (cf. `DetectionCandidatePane`).
    var existingPattern: RecurringPattern? = nil

    private var gaps: [Int] {
        zip(candidate.occurrences, candidate.occurrences.dropFirst()).map { earlier, later in
            Calendar.current.dateComponents([.day], from: earlier, to: later).day ?? 0
        }
    }

    private var relativeAmountDeviation: Double {
        abs(candidate.amountAvg) > 0 ? candidate.amountStdDev / abs(candidate.amountAvg) : 0
    }

    private var sortedOccurrences: [(date: Date, amount: Double)] {
        zip(candidate.occurrences, candidate.occurrenceAmounts)
            .map { (date: $0, amount: $1) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(candidate.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        .frame(width: 36, height: 36)
                        .background((candidate.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success).opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name).font(AppTheme.Typography.bodyMedium)
                        Text(LocalizedStringKey(candidate.frequency.label))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(abs(candidate.amountAvg), format: .currency(code: "EUR"))
                            .font(AppTheme.Typography.moneySmall)
                            .foregroundStyle(candidate.amountAvg < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        Text("\(Int(candidate.confidence * 100))% confiance")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, 2)
            }

            if let existing = existingPattern {
                let drifted = candidate.differsFrom(existing)
                Section {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                        Image(systemName: drifted ? "exclamationmark.triangle.fill" : "link.circle.fill")
                            .foregroundStyle(drifted ? AppTheme.Colors.warning : AppTheme.Colors.accent)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(drifted ? "Ce récurrent a changé depuis sa création" : "Un récurrent existe déjà pour ce tiers")
                                .font(AppTheme.Typography.labelMedium)
                            LabeledContent("Nom", value: existing.name)
                            LabeledContent("Montant suivi") {
                                Text(existing.displayAmount, format: .currency(code: "EUR"))
                                    .foregroundStyle(drifted ? AppTheme.Colors.warning : AppTheme.Colors.textPrimary)
                            }
                            if drifted {
                                LabeledContent("Montant détecté récemment") {
                                    Text(abs(candidate.amountAvg), format: .currency(code: "EUR"))
                                }
                            }
                            LabeledContent("Fréquence") {
                                Text(LocalizedStringKey(existing.frequency.label))
                            }
                            LabeledContent("Statut", value: existing.isActive ? "Actif" : "Inactif")
                        }
                    }
                    .padding(.vertical, 2)
                } footer: {
                    Text(drifted
                         ? "Le prix ou l'échéance a bougé sans que le motif suivi ne soit mis à jour — utilisez \"Mettre à jour\" pour le corriger avec les valeurs détectées, en conservant sa catégorie et son tier."
                         : "Ce candidat n'est donc pas proposé à la création — direction \"Gérer les récurrents\" pour corriger le motif existant si ses valeurs sont fausses.")
                        .font(.caption)
                }
            }

            Section("Pourquoi c'est détecté comme récurrent") {
                explanationRow(icon: "person.crop.circle", title: "Tiers identique",
                                detail: "\(candidate.occurrences.count) transactions attribuées au même tiers.")
                explanationRow(icon: "repeat", title: "Fréquence régulière",
                                detail: frequencyExplanation)
                explanationRow(icon: "eurosign.circle", title: "Montant quasi identique",
                                detail: amountExplanation)
                explanationRow(icon: "calendar", title: "Date d'échéance stable",
                                detail: dateExplanation)
            }

            Section("Occurrences détectées (\(candidate.occurrences.count))") {
                ForEach(Array(sortedOccurrences.enumerated()), id: \.offset) { _, occ in
                    LabeledContent {
                        Text(abs(occ.amount), format: .currency(code: "EUR"))
                    } label: {
                        Text(occ.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                    }
                }
            }
        }
        .nemorisFormStyle()
    }

    @ViewBuilder
    private func explanationRow(icon: String, title: LocalizedStringKey, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.success)
                .font(.caption)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppTheme.Typography.labelMedium)
                Text(detail)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var frequencyExplanation: String {
        let window = RecurringDetector.gapWindow(for: candidate.frequency)
        let gapList = gaps.map(String.init).joined(separator: ", ")
        return "Écarts observés entre les prélèvements : \(gapList) jour(s) — tous dans la fenêtre attendue pour une fréquence \(candidate.frequency.label.lowercased()) (\(window.lowerBound) à \(window.upperBound) jours)."
    }

    private var amountExplanation: String {
        let pct = relativeAmountDeviation * 100
        let tolerancePct = RecurringDetector.amountTolerance * 100
        return String(format: "Écart entre les montants observés : %.1f %% (tolérance autorisée : %.0f %%).", pct, tolerancePct)
    }

    private var dateExplanation: String {
        let tolerance = RecurringDetector.dateTolerance(for: candidate.frequency)
        let toleranceSuffix = tolerance > 1 ? "jours" : "jour"
        guard let anchor = candidate.anchorDay else {
            return "Fréquence quotidienne — pas d'ancrage de date à vérifier."
        }
        if candidate.frequency.usesDayOfMonthAnchor {
            let days = candidate.occurrences
                .map { String(Calendar.current.component(.day, from: $0)) }
                .joined(separator: ", ")
            let anchorLabel = anchor >= 29 ? "fin de mois" : "le \(anchor)"
            return "Jour du mois observé sur chaque occurrence : \(days) — ancré \(anchorLabel) (tolérance ±\(tolerance) \(toleranceSuffix))."
        }
        if candidate.frequency.usesWeekdayAnchor {
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.locale = AppLocalization.locale
            weekdayFormatter.dateFormat = "EEEE"
            let days = candidate.occurrences
                .map { weekdayFormatter.string(from: $0).capitalized }
                .joined(separator: ", ")
            let isoWeekdayNames = ["", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
            let anchorLabel = (1...7).contains(anchor) ? isoWeekdayNames[anchor] : "\(anchor)"
            return "Jour de la semaine observé sur chaque occurrence : \(days) — ancré le \(anchorLabel) (tolérance ±\(tolerance) \(toleranceSuffix))."
        }
        // .yearly
        let dayFormatter = DateFormatter()
        dayFormatter.locale = AppLocalization.locale
        dayFormatter.dateFormat = "d MMMM"
        let days = candidate.occurrences.map { dayFormatter.string(from: $0) }.joined(separator: ", ")
        return "Date observée chaque année : \(days) (tolérance ±\(tolerance) \(toleranceSuffix))."
    }
}
