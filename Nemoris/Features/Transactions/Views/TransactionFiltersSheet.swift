import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TransactionFiltersSheet: View {
    @Environment(AppState.self) private var appState
    // Fermeture via le panneau adaptatif (inspector macOS / sheet iOS), cf. AdaptivePane.
    @Environment(\.paneDismiss) private var paneDismiss

    let accounts: [Account]
    let allCategories: [Category]
    let allTags: [Tag]
    @Binding var tiersSearchText: String
    @Binding var selectedCategoryId: Int
    @Binding var filterTagIds: Set<Int>
    @Binding var grouping: TransactionGrouping
    let onApply: () -> Void

    // Local copies to avoid re-rendering parent on every keystroke
    @State private var localTiersSearch: String = ""

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Form {
                Section {
                    if accounts.isEmpty {
                        Text("Aucun compte disponible").foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        Picker("Compte", selection: Binding(
                            get: { appState.selectedAccountId ?? accounts.first?.id ?? 0 },
                            set: { newValue in
                                appState.selectedAccountId = newValue
                                if newValue == 0 {
                                    appState.selectedAccountName = "Tous les comptes"
                                } else {
                                    appState.selectedAccountName = accounts.first(where: { $0.id == newValue })?.name ?? "Compte"
                                }
                            }
                        )) {
                            // Sentinel : tag 0 = tous les comptes confondus.
                            // Aucun account.id ne vaut 0 (AUTOINCREMENT démarre à 1).
                            Label("Tous les comptes", systemImage: "rectangle.stack.fill").tag(0)
                            ForEach(accounts.groupedByType, id: \.type) { group in
                                Section(group.type.label) {
                                    ForEach(group.accounts) { a in Text(a.name).tag(a.id) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Compte")
                } footer: {
                    if (appState.selectedAccountId ?? 0) == 0 {
                        Text("Mode tous comptes : les transactions de tous les comptes sont mélangées. Le solde réel est masqué (incohérent inter-comptes) ; seul le flux net de la période est affiché.")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Section("Période") {
                    DatePicker("Du", selection: $appState.filterFromDate, displayedComponents: .date)
                    DatePicker("Au", selection: $appState.filterToDate, displayedComponents: .date)
                }

                Section("Recherche") {
                    TextField("Filtrer par tiers ou libellé…", text: $localTiersSearch)
                        .autocorrectionDisabled()

                    Picker("Catégorie", selection: $selectedCategoryId) {
                        Text("Toutes").tag(-1)
                        Text("Non catégorisé").tag(-2)
                        ForEach(allCategories) { c in Text(c.name).tag(c.id) }
                    }
                }

                if !allTags.isEmpty {
                    Section {
                        if filterTagIds.isEmpty {
                            Text("Tous les tags").foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            // Chips des tags sélectionnés
                            TagChipsRow(
                                tags: allTags.filter { filterTagIds.contains($0.id) },
                                onRemove: { filterTagIds.remove($0) }
                            )
                        }
                        // Liste toggleable
                        ForEach(allTags) { tag in
                            Button {
                                if filterTagIds.contains(tag.id) { filterTagIds.remove(tag.id) }
                                else { filterTagIds.insert(tag.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: filterTagIds.contains(tag.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(filterTagIds.contains(tag.id) ? AppTheme.Colors.accentSecondary : AppTheme.Colors.textSecondary)
                                    Text(tag.name).foregroundStyle(AppTheme.Colors.textPrimary)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Tags")
                            Spacer()
                            if !filterTagIds.isEmpty {
                                Button("Effacer") { filterTagIds.removeAll() }
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                            }
                        }
                    }
                }

                Section {
                    Picker("Grouper par", selection: $grouping) {
                        ForEach(TransactionGrouping.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Picker de densité — 3 paliers (compact / normal / confortable).
                    // Tap haptique pour confirmer le changement.
                    Picker(selection: Binding(
                        get: { appState.transactionDensity },
                        set: { newValue in
                            appState.transactionDensity = newValue
                            HapticService.shared.selection()
                        }
                    )) {
                        ForEach(TransactionDensity.allCases) { d in
                            Label(d.label, systemImage: d.systemIcon).tag(d)
                        }
                    } label: {
                        Text("Densité")
                    }
                    Text(appState.transactionDensity.description)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: {
                    Text("Affichage")
                }

                Section {
                    Button("Réinitialiser les filtres") {
                        localTiersSearch   = ""
                        tiersSearchText    = ""
                        selectedCategoryId = -1
                        filterTagIds       = []
                    }
                    .foregroundStyle(AppTheme.Colors.danger)
                }
            }
            .nemorisFormStyle()
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { localTiersSearch = tiersSearchText }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer", systemImage: "xmark") { paneDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer", systemImage: "checkmark") {
                        tiersSearchText = localTiersSearch
                        onApply()
                        paneDismiss()
                    }
                }
            }
        }
    }
}
