import Foundation
import SwiftUI
import Observation

@Observable
final class AppState {
    var selectedAccountId: Int? = 2
    var selectedAccountName: String = ""
    var filterFromDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var filterToDate: Date = Date()
    var importStatus: String = "Aucun import lance"
    var dataRefreshToken: UUID = UUID()

    // Persisté : "system" | "light" | "dark"
    var colorSchemeRaw: String = UserDefaults.standard.string(forKey: "appColorScheme") ?? "system" {
        didSet { UserDefaults.standard.set(colorSchemeRaw, forKey: "appColorScheme") }
    }

    var preferredColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}
