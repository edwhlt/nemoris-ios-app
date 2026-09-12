import SwiftUI
import Charts
import TipKit

struct EnvelopeListView: View {
    @Bindable var vm: BudgetViewModel
    @State private var showAdd = false
    @State private var showSuggestions = false
    @State private var editingEnvelope: BudgetEnvelope?

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            List {
                let active = vm.envelopes.filter { $0.isActive }
                if active.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "envelope",
                            title: "Aucune enveloppe",
                            message: "Définissez un budget par catégorie."
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(active) { env in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(env.name)
                                    .font(AppTheme.Typography.bodyMedium)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Text(LocalizedStringKey(env.period.label))
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            Text(env.amount, format: .currency(code: "EUR"))
                                .font(AppTheme.Typography.moneySmall)
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingEnvelope = env }
                        .rowActions(trailing: [
                            RowAction("Supprimer", systemImage: "trash", role: .destructive) { vm.deleteEnvelope(id: env.id) }
                        ])
                        .macGroupedRow(first: env.id == active.first?.id, last: env.id == active.last?.id)
                    }
                }
            }
            #if os(macOS)
            // Same policy as TricountListView/TransactionsView: .plain =
            // a neutral base for the custom cards drawn by macGroupedRow.
            .listStyle(.plain)
            .macGroupedListTopGap()
            #endif
            .scrollContentBackground(.hidden)
        }
        .localizedNavigationTitle("Enveloppes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Créer une enveloppe", systemImage: "plus")
                    }
                    Button {
                        showSuggestions = true
                    } label: {
                        Label("Suggérer (90 j)", systemImage: "wand.and.stars")
                    }
                } label: {
                    Image(systemName: "plus")
                        .tint(AppTheme.Colors.accent)
                }
            }
        }
        .adaptivePane(isPresented: $showAdd) { EnvelopeEditSheet(vm: vm, envelope: nil) }
        .adaptiveEntityPane(
            item: $editingEnvelope,
            title: "Enveloppe",
            refresh: { e in vm.envelopes.first { $0.id == e.id } },
            onDelete: { vm.deleteEnvelope(id: $0.id) }
        ) { env in
            EnvelopeDetailPane(envelope: env, categories: vm.categories)
        } edit: { env in
            EnvelopeEditSheet(vm: vm, envelope: env)
        }
        .adaptivePane(isPresented: $showSuggestions) {
            EnvelopeSuggestionSheet(
                viewModel: vm,
                existingEnvelopes: vm.envelopes,
                allCategories: vm.categories
            )
        }
    }
}
