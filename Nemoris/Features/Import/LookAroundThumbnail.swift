import SwiftUI
import MapKit

/// Petit thumbnail Apple Look Around (vue street-view) pour un POI géolocalisé.
///
/// Fetch lazy via `MKLookAroundSceneRequest` au `.task` :
///   - Si Look Around est dispo pour la zone (centres urbains majeurs ↗ couverture
///     mondiale en expansion), on affiche un mini preview interactif (`LookAroundPreview`).
///   - Sinon, on n'affiche rien du tout → la cellule reste compacte.
///
/// Utile dans `PayeeCreationFormSheet` / `EnrichmentSheetView` pour aider l'utilisateur
/// à **reconnaître visuellement** un commerçant (la devanture du restaurant, etc.).
struct LookAroundThumbnail: View {
    let coordinate: CLLocationCoordinate2D
    var size: CGFloat = 60

    @State private var scene: MKLookAroundScene?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let scene {
                LookAroundPreview(initialScene: scene, allowsNavigation: false, badgePosition: .bottomTrailing)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.Colors.surfaceSecondary, lineWidth: 0.5)
                    )
            } else if !didLoad {
                // Placeholder pendant le chargement (court)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemFill))
                    ProgressView().controlSize(.mini)
                }
                .frame(width: size, height: size)
            }
            // Si didLoad == true et scene == nil → on n'affiche rien (Look Around indisponible ici)
        }
        .task(id: coordinateKey) {
            await loadScene()
        }
    }

    /// Cle stable pour redéclencher le fetch si la coord change.
    private var coordinateKey: String {
        "\(coordinate.latitude)|\(coordinate.longitude)"
    }

    private func loadScene() async {
        guard scene == nil, !didLoad else { return }
        let request = MKLookAroundSceneRequest(coordinate: coordinate)
        let fetched = try? await request.scene
        await MainActor.run {
            self.scene = fetched
            self.didLoad = true
        }
    }
}
