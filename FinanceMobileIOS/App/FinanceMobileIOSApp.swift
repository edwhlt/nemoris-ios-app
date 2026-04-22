import SwiftUI

@main
struct FinanceMobileIOSApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(appState)
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
