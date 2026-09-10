//
//  WidgetShared.swift
//  NemorisWidget
//
//  Palette et gate d'accès Pro partagés par tous les widgets du bundle.
//

import WidgetKit
import SwiftUI
import StoreKit

// MARK: - Nemoris palette (widget-local, no AppTheme access from extension)

extension Color {
    /// Nemoris forest-teal — income, positive balance, under-budget
    static let nSuccess = Color(red: 0.239, green: 0.667, blue: 0.510)
    /// Nemoris terracotta — expense, negative balance, over-budget
    static let nDanger  = Color(red: 0.761, green: 0.353, blue: 0.275)
    /// Nemoris amber — budget warning threshold (80-100 %)
    static let nWarning = Color(red: 0.769, green: 0.604, blue: 0.353)
    /// Nemoris accent teal — progress bars, arc fill (healthy)
    static let nAccent  = Color(red: 0.322, green: 0.722, blue: 0.588)
}

// MARK: - Shared money formatting

/// Formatage compact partagé par tous les widgets (pas de `NumberFormatter` par
/// vue — même convention `k€` que `NemorisWidgetEntryView.formatted`).
func widgetFormattedAmount(_ value: Double, signed: Bool = false) -> String {
    let abs = Swift.abs(value)
    let sign = value < 0 ? "-" : (signed && value > 0 ? "+" : "")
    if abs >= 1_000 {
        return "\(sign)\(String(format: "%.1f", abs / 1_000))k€"
    }
    return "\(sign)\(String(format: "%.0f", abs))€"
}

// MARK: - Access gate (Pro)

/// Niveau d'accès résolu depuis l'extension widget. Miroir volontaire de
/// `AccessLevel` (app principale, `PurchaseManager.swift`) — même doctrine
/// anti-triche : jamais un flag stocké en `UserDefaults`, toujours recalculé
/// depuis les transactions StoreKit vérifiées cryptographiquement. L'extension
/// widget est un PROCESS SÉPARÉ de l'app (pas d'accès à `PurchaseManager`), mais
/// `Transaction.currentEntitlements` est directement lisible depuis n'importe
/// quelle cible signée par la même équipe — aucun App Group nécessaire ici.
enum WidgetAccessLevel: Int, Comparable {
    case free = 0
    case pro = 1
    case lifetime = 2
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum WidgetAccessGate {
    // Doit rester synchronisé avec `AppConstants.Store` (app principale).
    private static let monthlyID  = "fr.hedwin.nemoris.subscription.monthly"
    private static let yearlyID   = "fr.hedwin.nemoris.subscription.yearly"
    private static let lifetimeID = "fr.hedwin.nemoris.lifetime"

    /// Recalcule le niveau d'accès à chaque appel — un provider de timeline tourne
    /// de toute façon périodiquement, pas besoin de cache local.
    static func currentAccessLevel() async -> WidgetAccessLevel {
        var highest = WidgetAccessLevel.free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            guard tx.revocationDate == nil else { continue }
            switch tx.productID {
            case lifetimeID:
                highest = .lifetime
            case monthlyID, yearlyID:
                if highest < .pro { highest = .pro }
            default:
                break
            }
        }
        return highest
    }

    static func isPro(_ level: WidgetAccessLevel) -> Bool { level >= .pro }
}

// MARK: - Empty state (module without data yet)

/// Affichée quand l'utilisateur n'a encore rien saisi dans le module — pas un
/// "0 €" trompeur (qui laisserait croire que le patrimoine/portefeuille est
/// réellement nul), une invitation à ouvrir l'app.
struct EmptyModuleView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Locked placeholder (Pro-only widgets)

/// Écran de verrouillage compact affiché par un widget Pro quand l'utilisateur
/// n'a pas (ou plus) l'accès — jamais de fuite de données derrière le lock,
/// contrairement au comportement précédent du widget Budget qui n'était pas gardé.
struct WidgetLockedView: View {
    let title: String
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
        case .accessoryRectangular, .accessoryInline:
            Label("Nemoris Pro requis", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        default:
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Fonctionnalité Pro")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
