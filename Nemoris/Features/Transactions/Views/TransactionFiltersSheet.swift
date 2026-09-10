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

    /// Catégories aplaties en pré-ordre (parent puis ses enfants) avec la
    /// profondeur de chacune — un `Picker` ne peut pas rendre un vrai arbre,
    /// mais l'indentation suffit à transmettre la hiérarchie sans y perdre la
    /// sélection directe d'un parent OU d'un enfant (contrairement à une vraie
    /// arborescence pliable, hors de portée d'un simple `Picker`).
    private var categoryPickerEntries: [(node: CategoryNode, depth: Int)] {
        CategoryNode.flattenedForest(CategoryNode.buildForest(from: allCategories))
    }

    /// Suggestions de tiers pour l'autocomplétion — noms déjà connus qui
    /// contiennent la saisie, le tiers déjà retenu exclu (il n'y a rien à
    /// proposer de plus une fois qu'il est choisi).
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
                                Section(LocalizedStringKey(group.type.label)) {
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

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Tiers…", text: $localPayeeSearch)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        // Suggestions d'autocomplétion — tap = remplit le champ
                        // avec le nom exact (le filtre reste un `LIKE`, pas une
                        // égalité stricte, mais un nom exact évite les faux
                        // positifs d'un tiers dont le nom en contient un autre).
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

                    // Aplatie en pré-ordre avec indentation par profondeur —
                    // un `Picker` ne peut pas rendre un vrai arbre pliable,
                    // mais l'indentation transmet la hiérarchie sans rien
                    // retirer : parent ET enfants restent sélectionnables.
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
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // barre d'outils native laisse le bureau de l'utilisateur
            // transparaître (retour d'usage 2026-08-21). Cf. le commentaire
            // de `macSheetChrome` dans AdaptivePane.swift.
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
    }
}
