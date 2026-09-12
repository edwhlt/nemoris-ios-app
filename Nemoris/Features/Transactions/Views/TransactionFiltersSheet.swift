import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TransactionFiltersSheet: View {
    @Environment(AppState.self) private var appState
    // Dismissal via the adaptive pane (macOS inspector / iOS sheet), see AdaptivePane.
    @Environment(\.paneDismiss) private var paneDismiss

    let accounts: [Account]
    let allCategories: [Category]
    let allTags: [Tag]
    let allTiers: [Tiers]
    @Binding var payeeSearchText: String
    @Binding var labelSearchText: String
    @Binding var selectedCategoryId: Int
    @Binding var filterTagIds: Set<Int>
    @Binding var grouping: TransactionGrouping
    let onApply: () -> Void

    // Local copies to avoid re-rendering parent on every keystroke
    @State private var localPayeeSearch: String = ""
    @State private var localLabelSearch: String = ""
    @State private var showAccountPicker = false

    /// Categories flattened in pre-order (a parent then its children) with each
    /// one's depth — a `Picker` can't render a real tree,
    /// but indentation is enough to convey the hierarchy without losing
    /// direct selection of a parent OR a child (unlike a real
    /// foldable tree, out of reach of a plain `Picker`).
    private var categoryPickerEntries: [(node: CategoryNode, depth: Int)] {
        CategoryNode.flattenedForest(CategoryNode.buildForest(from: allCategories))
    }

    /// Payee suggestions for autocomplete — already-known names that
    /// contain what's typed, excluding the payee already chosen (there's nothing
    /// more to suggest once it's picked).
    private var payeeSuggestions: [String] {
        guard !localPayeeSearch.isEmpty else { return [] }
        let names = Set(allTiers.map(\.name))
        guard !names.contains(localPayeeSearch) else { return [] }
        return names
            .filter { $0.localizedCaseInsensitiveContains(localPayeeSearch) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        @Bindable var appState = appState
            Form {
                Section {
                    if accounts.isEmpty {
                        Text("Aucun compte disponible").foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        // Sentinel: 0/nil = across all accounts.
                        // No account.id is ever 0 (AUTOINCREMENT starts at 1).
                        Button {
                            showAccountPicker = true
                        } label: {
                            HStack {
                                Text("Compte").foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                                // A runtime `String` (the account's name
                                // never is, but the fallback is):
                                // `Text(String)` stays verbatim without this wrap
                                // — see CLAUDE.md §5.
                                Text(LocalizedStringKey(appState.selectedAccountName.isEmpty ? "Tous les comptes" : appState.selectedAccountName))
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
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

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Tiers…", text: $localPayeeSearch)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        // Autocomplete suggestions — tapping fills the field
                        // with the exact name (the filter stays a `LIKE`, not a
                        // strict equality, but an exact name avoids false
                        // positives from a payee whose name contains another's).
                        if !payeeSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(payeeSuggestions, id: \.self) { name in
                                        Button {
                                            localPayeeSearch = name
                                        } label: {
                                            Text(name)
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
                                                .foregroundStyle(AppTheme.Colors.accent)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    TextField("Libellé…", text: $localLabelSearch)
                        .autocorrectionDisabled()

                    // Flattened in pre-order with depth-based indentation —
                    // a `Picker` can't render a real foldable tree,
                    // but indentation conveys the hierarchy without
                    // removing anything: both a parent AND its children stay selectable.
                    Picker("Catégorie", selection: $selectedCategoryId) {
                        Text("Toutes").tag(-1)
                        Text("Non catégorisé").tag(-2)
                        ForEach(categoryPickerEntries, id: \.node.id) { entry in
                            Text(String(repeating: "    ", count: entry.depth) + entry.node.category.name)
                                .tag(entry.node.category.id)
                        }
                    }
                } header: {
                    Text("Recherche")
                } footer: {
                    Text("Tiers et libellé se combinent : renseigne les deux pour restreindre aux transactions qui correspondent aux deux à la fois.")
                }

                if !allTags.isEmpty {
                    Section {
                        if filterTagIds.isEmpty {
                            Text("Tous les tags").foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            // Selected tag chips
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

                    // Density picker — 3 levels (compact / normal / comfortable).
                    // A haptic tap to confirm the change.
                    Picker(selection: Binding(
                        get: { appState.transactionDensity },
                        set: { newValue in
                            appState.transactionDensity = newValue
                            HapticService.shared.selection()
                        }
                    )) {
                        ForEach(TransactionDensity.allCases) { d in
                            Label(LocalizedStringKey(d.label), systemImage: d.systemIcon).tag(d)
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
                        localPayeeSearch   = ""
                        localLabelSearch   = ""
                        payeeSearchText    = ""
                        labelSearchText    = ""
                        selectedCategoryId = -1
                        filterTagIds       = []
                    }
                    .foregroundStyle(AppTheme.Colors.danger)
                }
            }
            .nemorisFormStyle()
            .onAppear {
                localPayeeSearch = payeeSearchText
                localLabelSearch = labelSearchText
            }
            // `.paneChrome` draws its own bars on macOS-sheet — the native
            // toolbar lets the user's desktop
            // show through. See the comment
            // on `macSheetChrome` in AdaptivePane.swift.
            .paneChrome(
                "Filtres",
                cancelLabel: "Fermer", onCancel: { paneDismiss() },
                confirmLabel: "Appliquer", confirmIcon: "checkmark",
                onConfirm: {
                    payeeSearchText = localPayeeSearch
                    labelSearchText = localLabelSearch
                    onApply()
                    paneDismiss()
                }
            )
            .adaptivePane(isPresented: $showAccountPicker) {
                AccountSearchSheet(
                    accounts: accounts,
                    selectedId: (appState.selectedAccountId ?? 0) == 0 ? nil : appState.selectedAccountId,
                    title: "Choisir un compte",
                    specialLabel: "Tous les comptes",
                    specialIcon: "rectangle.stack.fill"
                ) { picked in
                    if let picked {
                        appState.selectedAccountId = picked.id
                        appState.selectedAccountName = picked.name
                    } else {
                        appState.selectedAccountId = 0
                        appState.selectedAccountName = "Tous les comptes"
                    }
                }
            }
    }
}
