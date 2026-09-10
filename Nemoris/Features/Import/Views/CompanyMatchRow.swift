import SwiftUI

/// Affichage à DEUX NIVEAUX d'un résultat de registre d'entreprises.
///
/// Pourquoi deux niveaux : une enseigne est une personne morale (« OULLIDIS », « CSF »,
/// « SAS SISENS ») qui exploite N établissements. Le siège social est souvent à l'autre
/// bout du pays, alors que le commerce facturé est une BRANCHE qu'on reconnaît à son
/// adresse. Écraser tout ça en une ligne plate — ce que faisait l'ancienne liste — perdait
/// justement l'information qui permet d'identifier le bon commerce.
///
/// Taper l'ENTREPRISE remplit le nom et le SIREN.
/// Taper un ÉTABLISSEMENT remplit en plus l'adresse, le SIRET et les coordonnées.
struct CompanyMatchRow: View {

    let ranked: RankedCompany
    let onPickCompany: (CompanyMatch) -> Void
    let onPickEstablishment: (CompanyMatch, Establishment) -> Void

    @State private var isExpanded: Bool

    /// `initiallyExpanded: true` déplie le meilleur résultat d'entrée — les
    /// établissements (et leurs adresses, LE critère d'identification) étaient
    /// invisibles derrière un disclosure replié : l'utilisateur ne voyait que
    /// « N établissements » sans savoir qu'un tap les révélait.
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
        // Ordonnés par le classement : le plus plausible d'abord, les fermés en dernier.
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

    // MARK: Niveau 2 — les établissements

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

                // Honnêteté d'affichage : `matching_etablissements` ne renvoie QUE les
                // branches dont le nom matche la requête, pas toutes celles de l'entreprise.
                // Laisser croire à une liste exhaustive serait mensonger. Pas de bouton
                // « voir tout » : l'API recherche-entreprises ne sait PAS lister tous les
                // établissements d'un SIREN (q=<siren> renvoie l'entité avec
                // matching_etablissements VIDE — vérifié) ; il faudrait l'API Sirene INSEE
                // avec token, hors scope.
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
                // L'adresse EST le critère d'identification : c'est elle qui distingue
                // deux boutiques de la même enseigne.
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
