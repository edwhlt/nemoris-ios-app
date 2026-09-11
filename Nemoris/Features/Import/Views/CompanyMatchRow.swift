import SwiftUI

/// TWO-LEVEL display of a company registry result.
///
/// Why two levels: a brand is a legal entity ("OULLIDIS", "CSF", "SAS
/// SISENS") operating N establishments. The head office is often at the other
/// end of the country, while the billed shop is a BRANCH recognized by its
/// address. Flattening all that into one row would lose exactly the
/// information that identifies the right shop.
///
/// Tapping the COMPANY fills in the name and the SIREN.
/// Tapping an ESTABLISHMENT also fills in the address, the SIRET and the
/// coordinates.
struct CompanyMatchRow: View {

    let ranked: RankedCompany
    let onPickCompany: (CompanyMatch) -> Void
    let onPickEstablishment: (CompanyMatch, Establishment) -> Void

    @State private var isExpanded: Bool

    /// `initiallyExpanded: true` unfolds the best result from the start —
    /// otherwise the establishments (and their addresses, THE identification
    /// criterion) sit behind a collapsed disclosure, and the user only sees
    /// "N establishments" without knowing a tap reveals them.
    init(ranked: RankedCompany,
         initiallyExpanded: Bool = false,
         onPickCompany: @escaping (CompanyMatch) -> Void,
         onPickEstablishment: @escaping (CompanyMatch, Establishment) -> Void) {
        self.ranked = ranked
        self.onPickCompany = onPickCompany
        self.onPickEstablishment = onPickEstablishment
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var establishments: [Establishment] {
        // Ordered by the ranking: the most plausible first, closed ones last.
        ranked.rankedEstablishments.compactMap { candidate in
            ranked.match.allEstablishments.first { $0.id == candidate.candidate.id }
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            establishmentList
        } label: {
            companyHeader
        }
    }

    // MARK: Niveau 1 — l'entreprise

    private var companyHeader: some View {
        Button {
            onPickCompany(ranked.match)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ranked.match.legalName.titleCased)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if !ranked.match.isActive {
                            statusBadge("Fermée", AppTheme.Colors.danger)
                        }
                        if let count = ranked.match.openEstablishmentCount, count > 1 {
                            Text("\(count) établissements")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Text("SIREN \(ranked.match.siren)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                    }
                }
                Spacer(minLength: 4)
                Text("\(Int((ranked.score * 100).rounded())) %")
                    .font(.caption2.bold())
                    .foregroundStyle(scoreColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scoreColor: Color {
        switch ranked.score {
        case 0.75...:  return AppTheme.Colors.success
        case 0.45..<0.75: return AppTheme.Colors.warning
        default: return AppTheme.Colors.textSecondary
        }
    }

    // MARK: Level 2 — the establishments

    @ViewBuilder
    private var establishmentList: some View {
        if establishments.isEmpty {
            Text("Aucune adresse rattachée.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(establishments.enumerated()), id: \.element.id) { index, establishment in
                    Button {
                        onPickEstablishment(ranked.match, establishment)
                    } label: {
                        establishmentRow(establishment)
                    }
                    .buttonStyle(.plain)
                    if index < establishments.count - 1 {
                        Divider().padding(.leading, 4)
                    }
                }

                // Honest display: `matching_etablissements` returns ONLY the branches whose
                // name matches the query, not all of the company's. Implying an exhaustive
                // list would be misleading. No "see all" button: the recherche-entreprises
                // API can't list every establishment of a SIREN (q=<siren> returns the
                // entity with an EMPTY matching_etablissements); that would need the INSEE
                // Sirene API with a token.
                if let total = ranked.match.openEstablishmentCount, total > establishments.count {
                    Divider().padding(.leading, 4)
                    Text("\(total - establishments.count) autre(s) établissement(s) non affiché(s).")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .padding(.top, 8)
                }
            }
            .padding(.top, 4)
        }
    }

    private func establishmentRow(_ e: Establishment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: e.isHeadquarters ? "building.columns.fill" : "mappin.circle.fill")
                .font(.caption)
                .foregroundStyle(e.isActive ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                if let name = e.displayName, !name.isEmpty {
                    Text(name.titleCased)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                }
                // The address IS the identification criterion: it's what tells two shops of
                // the same brand apart.
                if let address = e.addressLine {
                    Text(address)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 5) {
                    if e.isHeadquarters { statusBadge("Siège", AppTheme.Colors.accent) }
                    if e.isFormerHeadquarters { statusBadge("Ancien siège", AppTheme.Colors.warning) }
                    if !e.isActive { statusBadge("Fermé", AppTheme.Colors.danger) }
                    Text(e.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(e.isActive ? 1 : 0.55)
        .contentShape(Rectangle())
    }

    private func statusBadge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
