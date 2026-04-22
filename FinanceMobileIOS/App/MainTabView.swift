import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.pie")
                }

            TransactionsView()
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.rectangle")
                }

            ReferenceDataView()
                .tabItem {
                    Label("Données", systemImage: "square.grid.2x2")
                }

            ImportView()
                .tabItem {
                    Label("Import CSV", systemImage: "square.and.arrow.down.fill")
                }

            TricountListView()
                .tabItem {
                    Label("Tricount", systemImage: "person.2.fill")
                }
        }
    }
}
