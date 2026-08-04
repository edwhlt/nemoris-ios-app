import SwiftUI
import Charts
import TipKit

struct RecurringManagementView: View {
    @Bindable var vm: BudgetViewModel
    @State private var showAddSheet = false
    @State private var editingPattern: RecurringPattern?

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            List {
                let active   = vm.patterns.filter { $0.isActive }
                let inactive = vm.patterns.filter { !$0.isActive }

                if active.isEmpty && inactive.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "arrow.clockwise.circle",
                            title: "Aucun récurrent",
                            message: "Détectez vos dépenses récurrentes ou ajoutez-en manuellement."
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    if !active.isEmpty {
                        Section("Actifs") {
                            ForEach(active) { p in
                                RecurringPatternRow(pattern: p, categories: vm.categories)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingPattern = p }
                                    .rowActions(trailing: [
                                        RowAction("Supprimer", systemImage: "trash", role: .destructive) { vm.deletePattern(id: p.id) },
                                        RowAction("Désactiver", systemImage: "pause.circle", tint: AppTheme.Colors.warning) { vm.togglePattern(p) }
                                    ])
                            }
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                    if !inactive.isEmpty {
                        Section("Inactifs") {
                            ForEach(inactive) { p in
                                RecurringPatternRow(pattern: p, categories: vm.categories)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingPattern = p }
                                    .rowActions(trailing: [
                                        RowAction("Supprimer", systemImage: "trash", role: .destructive) { vm.deletePattern(id: p.id) },
                                        RowAction("Réactiver", systemImage: "play.circle", tint: AppTheme.Colors.success) { vm.togglePattern(p) }
                                    ])
                            }
                        }
                        .listRowBackground(AppTheme.Colors.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Récurrents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .tint(AppTheme.Colors.accent)
            }
        }
        .adaptivePane(isPresented: $showAddSheet) { PatternEditSheet(vm: vm, pattern: nil) }
        .adaptiveEntityPane(
            item: $editingPattern,
            title: "Récurrent",
            refresh: { p in vm.patterns.first { $0.id == p.id } },
            onDelete: { vm.deletePattern(id: $0.id) }
        ) { p in
            PatternDetailPane(pattern: p, categories: vm.categories)
        } edit: { p in
            PatternEditSheet(vm: vm, pattern: p)
        }
    }
}
