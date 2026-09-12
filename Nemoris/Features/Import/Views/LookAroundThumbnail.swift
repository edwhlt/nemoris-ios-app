import SwiftUI
import MapKit

/// Small Apple Look Around (street-view) thumbnail for a geolocated POI.
///
/// Lazy fetch via `MKLookAroundSceneRequest` in `.task`:
///   - If Look Around is available for the area (major city centers, with
///     worldwide coverage growing), a small interactive preview is shown
///     (`LookAroundPreview`).
///   - Otherwise nothing is shown at all → the cell stays compact.
///
/// Used in `PayeeCreationFormSheet` / `EnrichmentSheetView` to help the user
/// **visually recognize** a merchant (the restaurant's storefront, etc.).
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
                // Placeholder while loading (short)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemFill))
                    ProgressView().controlSize(.mini)
                }
                .frame(width: size, height: size)
            }
            // If didLoad == true and scene == nil → show nothing (Look Around unavailable here)
        }
        .task(id: coordinateKey) {
            await loadScene()
        }
    }

    /// Stable key to re-trigger the fetch when the coordinate changes.
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
