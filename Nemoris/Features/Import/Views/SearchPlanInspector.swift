import SwiftUI

/// Makes VISIBLE what the planner decided.
///
/// It answers "how can the system learn that FLANCHES is a place?". Rather
/// than an opaque AI step, it shows what was removed from the name and lets
/// the user put it back with a tap. The splitting becomes inspectable and
/// correctable, and each correction is a candidate corpus entry.

// MARK: - "Removed from the name" chips

struct DroppedTokenChips: View {

    let extraction: MerchantLabelExtraction
    /// Puts the token back into the query and reruns the planning.
    let onRestore: (String) -> Void

    /// The same token can be removed several times (a city repeated in the brand):
    /// deduplicated so two identical chips aren't shown.
    private var chips: [DroppedToken] {
        var seen = Set<String>()
        return extraction.droppedTokens.filter { token in
            let key = "\(token.value)|\(token.reason.rawValue)"
            guard !seen.contains(key), !token.value.isEmpty else { return false }
            seen.insert(key)
            // Purely structural noise teaches the user nothing: only what could
            // legitimately be part of the shop's name is shown.
            return token.reason != .noise
        }
    }

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Retiré du nom recherché")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { token in
                        Button {
                            onRestore(token.value)
                        } label: {
                            HStack(spacing: 4) {
                                Text(token.value)
                                    .font(.caption2.weight(.medium))
                                Text(token.reason.displayLabel)
                                    .font(.system(size: 9))
                                    .opacity(0.65)
                                Image(systemName: "arrow.uturn.left")
                                    .font(.system(size: 8, weight: .bold))
                                    .opacity(0.5)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(color(for: token.reason).opacity(0.13), in: Capsule())
                            .foregroundStyle(color(for: token.reason))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Ces éléments ne sont pas envoyés au registre : y mettre la ville fait échouer la recherche. Tape une puce pour la réintégrer au nom.")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
            }
        }
    }

    private func color(for reason: DropReason) -> Color {
        switch reason {
        case .locality, .postalCode, .departmentCode, .countryCode:
            return AppTheme.Colors.accent
        case .processorPrefix, .cardMarker, .transactionId, .paymentReference, .date, .currency:
            return AppTheme.Colors.textSecondary
        case .noise:
            return AppTheme.Colors.textSecondary
        }
    }
}

// MARK: - "Search details"

struct SearchDetailsDisclosure: View {

    let result: MerchantSearchResult
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let locality = result.plan.locality {
                    detailLine(
                        icon: "mappin.and.ellipse",
                        title: "Commune résolue",
                        detail: localityDescription(locality)
                    )
                } else if let text = result.plan.extraction.primaryLocalityText {
                    detailLine(
                        icon: "questionmark.circle",
                        title: "Lieu non reconnu comme commune",
                        detail: "« \(text) » sert au tri sur les adresses, pas de filtre géographique."
                    )
                }

                detailLine(
                    icon: "magnifyingglass",
                    title: "Nom recherché",
                    detail: result.plan.extraction.nameQuery.isEmpty
                        ? "—" : "« \(result.plan.extraction.nameQuery) »"
                )

                Divider()

                ForEach(result.plan.attempts) { attempt in
                    attemptLine(attempt)
                }

                Divider()
                Text(result.costSummary)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Détails de la recherche")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(result.costSummary)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func detailLine(icon: String, title: LocalizedStringKey, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }

    private func localityDescription(_ locality: ResolvedLocality) -> String {
        var parts = [locality.displayName]
        if let insee = locality.inseeCode { parts.append("INSEE \(insee)") }
        if let dep = locality.departmentCode { parts.append("dép. \(dep)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func attemptLine(_ attempt: SearchAttempt) -> some View {
        let outcome = result.outcomes.first { $0.attemptId == attempt.id }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: outcome))
                .font(.system(size: 10))
                .foregroundStyle(color(for: outcome))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(attempt.id). \(attempt.rationale)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(subtitle(for: attempt, outcome: outcome))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.8))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// The query's real parameters. Never the full URL: no key or identifier may
    /// appear in a displayable or copyable surface.
    private func subtitle(for attempt: SearchAttempt, outcome: SearchAttemptOutcome?) -> String {
        var parts: [String] = []
        switch attempt.kind {
        case .companyRegistry(let query):
            parts.append("q=\(query.q)")
            if let c = query.codeCommune { parts.append("code_commune=\(c)") }
            if let c = query.codePostal { parts.append("code_postal=\(c)") }
            if let d = query.departement { parts.append("departement=\(d)") }
            if query.etatAdministratif == nil { parts.append("+fermées") }
        case .companyRegistryNearPoint(let lat, let lon, let radius, _):
            parts.append(String(format: "autour de %.3f,%.3f · %.0f km", lat, lon, radius))
        case .placeText(let query):
            parts.append("carte : \(query.text)")
        }
        if let outcome {
            switch outcome.status {
            case .ok:
                parts.append("→ \(outcome.resultCount) résultat(s), \(Int(outcome.elapsed * 1000)) ms")
            case .skipped(let reason):
                parts.append("→ ignorée (\(reason))")
            case .failed(let reason):
                parts.append("→ échec : \(reason)")
            }
        } else {
            parts.append("→ non exécutée")
        }
        return parts.joined(separator: " · ")
    }

    private func icon(for outcome: SearchAttemptOutcome?) -> String {
        guard let outcome else { return "circle.dashed" }
        switch outcome.status {
        case .ok: return outcome.resultCount > 0 ? "checkmark.circle.fill" : "circle"
        case .skipped: return "forward.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for outcome: SearchAttemptOutcome?) -> Color {
        guard let outcome else { return AppTheme.Colors.textSecondary.opacity(0.5) }
        switch outcome.status {
        case .ok: return outcome.resultCount > 0 ? AppTheme.Colors.success : AppTheme.Colors.textSecondary
        case .skipped: return AppTheme.Colors.textSecondary.opacity(0.6)
        case .failed: return AppTheme.Colors.warning
        }
    }
}

// MARK: - Disposition en flot

/// Lays the chips out in sequence and wraps when the width is reached.
/// `Layout` exists since iOS 16 / macOS 13: the project's target (18 / 14) is covered.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
