import SwiftUI
import TipKit

/// Draft state for creating/editing a Compte/Catégorie from `ReferenceDataView`.
/// (Les Tiers ont leur propre fiche riche, `PayeeDetailView` — cf. commentaire
/// de `ReferenceEditFormPane` plus bas.)
struct ReferenceEditDraft {
    var name = ""
    var parentCategoryId: Int? = nil
    var icon: String? = nil
    var accountType: String = "COURANT"
    /// v51 — voir `Account.excludedFromAggregates`.
    var excludedFromAggregates: Bool = false
}

/// Formulaire d'ajout/édition Compte/Catégorie, extrait de `ReferenceDataView`
/// en un View DÉDIÉ portant son PROPRE `@State`.
///
/// ⚠️ Pourquoi cette extraction est nécessaire (pas juste "plus propre") : sur
/// macOS, `.adaptivePane(isPresented:)` hébergé au niveau racine (inspecteur,
/// cf. `AdaptivePane.swift`) construit son contenu en appelant le closure
/// `paneContent()` UNE SEULE FOIS (`presentPane`), puis fige le résultat dans un
/// `AnyView`. Tout ce qui était calculé INLINE dans ce closure à partir d'un
/// `@State` du view APPELANT (ex. `editDraftName` sur `ReferenceDataView`) restait
/// donc gelé à sa valeur au moment de l'OUVERTURE du panneau —
/// `confirmDisabled: editDraftName.isEmpty` restait bloqué à `true` (nom vide au
/// moment d'« Ajouter ») même après avoir tapé un nom, car rien ne rappelait
/// jamais ce closure. Le bouton « Enregistrer » semblait mort (retour user,
/// 2026-08-18).
///
/// Un `@State` DÉCLARÉ SUR CE VIEW, en revanche, continue de déclencher un
/// ré-affichage de CE view (donc de `confirmDisabled`) à chaque frappe — SwiftUI
/// suit l'identité/le state d'un enfant indépendamment du fait que le parent qui
/// l'a construit soit lui-même figé. Règle à retenir : tout `.paneChrome`/
/// `confirmDisabled` dynamique hébergé en panneau racine macOS doit vivre dans un
/// View dédié avec son PROPRE `@State`, jamais dans une closure inline qui lit le
/// `@State` du parent.
///
/// ⚠️ Ne gère PLUS les Tiers (retour user 2026-08-19 : la création d'un tiers
/// doit exposer les MÊMES champs riches qu'à l'édition — localisation, groupe,
/// type, note… — pas un form minimal nom/regex/catégorie à compléter après
/// coup). `ReferenceDataView.startAdd()` route désormais directement vers
/// `PayeeDetailView(payee: nil, …)` pour `selectedTab == .tiers`.
struct ReferenceEditFormPane: View {
    let kind: ReferenceDataView.ReferenceTab
    let editItemId: Int?
    let categories: [Category]
    let onCancel: () -> Void
    let onSave: (ReferenceEditDraft) -> Void

    @State private var draft: ReferenceEditDraft
    @State private var showIconPicker = false

    init(
        kind: ReferenceDataView.ReferenceTab,
        editItemId: Int?,
        initial: ReferenceEditDraft,
        categories: [Category],
        onCancel: @escaping () -> Void,
        onSave: @escaping (ReferenceEditDraft) -> Void
    ) {
        self.kind = kind
        self.editItemId = editItemId
        self.categories = categories
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    /// Icône à afficher dans la preview : reflète l'icône RÉELLEMENT utilisée à
    /// l'affichage (custom si définie, sinon fallback auto sur le nom).
    private var previewCategoryIcon: String {
        Category(id: editItemId ?? 0, name: draft.name, parentId: draft.parentCategoryId, icon: draft.icon).displayIcon
    }

    var body: some View {
        Form {
            Section {
                TextField("Nom", text: $draft.name)
                    .autocorrectionDisabled()
            }
            if kind == .comptes {
                Section("Type de compte") {
                    Picker("Type", selection: $draft.accountType) {
                        ForEach(AccountType.allCases, id: \.rawValue) { t in
                            Text(LocalizedStringKey(t.label)).tag(t.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Toggle("Exclure des calculs", isOn: $draft.excludedFromAggregates)
                } footer: {
                    Text("Ce compte n'entrera plus dans les cumuls par catégorie, le budget, le tableau de bord ni le coach IA. Ses transactions restent visibles normalement sur son propre écran. Utile pour un compte de remboursements (mutuelle, assurance santé…).")
                }
            }
            if kind == .categories {
                Section {
                    TipView(CategoryHierarchyTip(), arrowEdge: .none)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("Catégorie parente") {
                    // Seules les racines (sans parent) peuvent être choisies comme parent
                    let roots = categories.filter { $0.parentId == nil && $0.id != editItemId }
                    Picker("Parent", selection: $draft.parentCategoryId) {
                        Text("Aucun (catégorie racine)").tag(Int?.none)
                        ForEach(roots) { c in
                            Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Button {
                        showIconPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(AppTheme.Colors.accent.opacity(0.15))
                                    .frame(width: 32, height: 32)
                                // Affiche l'icône RÉELLEMENT utilisée — soit celle stockée,
                                // soit le fallback auto calculé sur le nom.
                                Image(systemName: previewCategoryIcon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppTheme.Colors.accent)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Icône")
                                    .font(.body)
                                Text(draft.icon == nil
                                     ? "Auto (selon le nom) — tap pour personnaliser"
                                     : "Personnalisée — tap pour modifier")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: { Text("Icône") }
                footer: {
                    if draft.icon == nil {
                        Text("Si tu ne choisis rien, l'icône est calculée automatiquement depuis le nom. Toute icône choisie est mémorisée et a la priorité.")
                    }
                }
            }
        }
        .nemorisFormStyle()
        .adaptivePane(isPresented: $showIconPicker) {
            ScrollView {
                CategoryIconPicker(
                    selectedIcon: $draft.icon,
                    categoryName: draft.name,
                    isParent: draft.parentCategoryId == nil
                )
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .paneChrome("Choisir une icône",
                        cancelLabel: "Fermer", onCancel: { showIconPicker = false })
        }
        .paneChrome(editItemId == nil ? "Ajouter" : "Modifier",
                    cancelLabel: "Annuler", onCancel: onCancel,
                    confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                    confirmDisabled: draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    onConfirm: { onSave(draft) })
    }
}
