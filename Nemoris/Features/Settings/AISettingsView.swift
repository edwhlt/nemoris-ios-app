import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Panneau Settings dédié à l'IA Apple Foundation Models.
/// Explique au user dans quel cas l'IA est utilisée, quel est l'état actuel
/// (disponible / iOS trop ancien / hardware non éligible), et rassure sur le
/// fallback (Sirene + MapKit + Companies House continuent même sans IA).
///
/// AXE H — clarifier l'UX autour de la pré-requis iOS 26 + Apple Intelligence.
struct AISettingsView: View {

    /// État détaillé de l'IA pour cet appareil.
    enum AIStatus {
        case available                  // iOS 26 + hw Apple Intelligence OK
        case iosTooOld                  // iOS < 26
        case hardwareNotEligible        // iOS 26 mais hw non Apple Intelligence
        case appleIntelligenceDisabled  // iOS 26 + hw OK mais user a désactivé AI dans Settings

        var title: String {
            switch self {
            case .available:                  return "Activée"
            case .iosTooOld:                  return "iOS 26 requis"
            case .hardwareNotEligible:        return "Appareil non compatible"
            case .appleIntelligenceDisabled:  return "Apple Intelligence désactivée"
            }
        }

        var color: Color {
            switch self {
            case .available: return AppTheme.Colors.success
            default:         return AppTheme.Colors.warning
            }
        }

        var icon: String {
            switch self {
            case .available: return "checkmark.circle.fill"
            default:         return "exclamationmark.circle.fill"
            }
        }

        var detail: String {
            switch self {
            case .available:
                return "L'IA Apple Foundation Models tourne directement sur cet appareil. Aucune donnée n'est envoyée à un serveur. Elle est utilisée pour identifier les marchands inconnus lors d'un import ou d'une recherche manuelle."
            case .iosTooOld:
                return "Cette fonctionnalité nécessite iOS 26 ou supérieur. Mettez à jour votre appareil dans Réglages → Général → Mise à jour logicielle pour en profiter."
            case .hardwareNotEligible:
                return "Apple Intelligence nécessite un iPhone 15 Pro ou plus récent (iPad M1+, Mac M1+). L'enrichissement continue de fonctionner via les annuaires d'entreprise (Sirene, Companies House, etc.) et MapKit."
            case .appleIntelligenceDisabled:
                return "Apple Intelligence est désactivée sur cet appareil. Activez-la dans Réglages iOS → Apple Intelligence & Siri pour utiliser l'IA dans Nemoris."
            }
        }
    }

    @State private var status: AIStatus = .iosTooOld

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            List {
                // ── Statut actuel ─────────────────────────────────────────
                Section {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Image(systemName: status.icon)
                            .font(.system(size: 32))
                            .foregroundStyle(status.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.title)
                                .font(AppTheme.Typography.titleMedium)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text("Apple Foundation Models")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)

                    Text(status.detail)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("État actuel")
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Comment c'est utilisé ─────────────────────────────────
                Section {
                    AIUsageRow(
                        icon: "terminal",
                        title: "Lors de la création de requêtes SQL",
                        text: "Vous pouvez créer votre requête SQL afin de questionner vos données bancaires et d'investissement dans une conversation avec l'IA"
                    )
                    AIUsageRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Lors d'un import",
                        text: "Quand le moteur ne reconnaît pas un libellé, l'IA propose un nom canonique, une ville et un pays."
                    )
                    AIUsageRow(
                        icon: "magnifyingglass.circle",
                        title: "Recherche manuelle",
                        text: "Depuis la fiche d'un tier, vous pouvez relancer l'identification IA avec une requête personnalisée."
                    )
                } header: {
                    Text("Comment Nemoris utilise l'IA")
                } footer: {
                    Text("100% on-device. Aucune donnée bancaire ne quitte l'appareil.")
                        .font(.caption)
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Sources de secours ────────────────────────────────────
                Section {
                    AIUsageRow(
                        icon: "building.columns",
                        title: "Annuaires d'entreprise",
                        text: "Sirene (FR), Companies House (UK), Zefix (CH) — configurables dans Réglages → Sources de données."
                    )
                    AIUsageRow(
                        icon: "map",
                        title: "MapKit",
                        text: "Recherche de POI Apple. Disponible sans iOS 26 ni Apple Intelligence."
                    )
                    AIUsageRow(
                        icon: "tray.full",
                        title: "Moteur embarqué Nemoris",
                        text: "Identification par embeddings BERT MiniLM sur ~200 marchands canoniques fréquents."
                    )
                } header: {
                    Text("Sources d'enrichissement de secours")
                } footer: {
                    Text("Ces sources fonctionnent indépendamment de l'IA. Si l'IA n'est pas disponible, l'enrichissement reste fonctionnel.")
                        .font(.caption)
                }
                .listRowBackground(AppTheme.Colors.surface)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Intelligence artificielle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = Self.detectStatus() }
    }

    /// Détecte l'état actuel de Foundation Models sur cet appareil.
    /// On distingue plusieurs cas pour informer précisément le user.
    private static func detectStatus() -> AIStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if model.isAvailable {
                return .available
            }
            // iOS 26 mais pas dispo : on essaie de discriminer hw vs réglages.
            // L'API publique expose `availability` qui peut renvoyer plusieurs cas.
            switch model.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceDisabled
            case .unavailable(.deviceNotEligible):
                return .hardwareNotEligible
            case .unavailable(.modelNotReady):
                return .appleIntelligenceDisabled // En cours de DL → traité comme "non activé"
            case .unavailable:
                return .hardwareNotEligible
            }
        }
        #endif
        return .iosTooOld
    }
}

// MARK: - Row helper

private struct AIUsageRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(text)
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
