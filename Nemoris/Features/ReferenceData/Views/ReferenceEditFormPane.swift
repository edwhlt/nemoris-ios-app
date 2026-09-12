import SwiftUI
import TipKit

/// Draft state for creating/editing a Compte/Catégorie from `ReferenceDataView`.
/// (Payees have their own rich form, `PayeeDetailView` — see the
/// `ReferenceEditFormPane` comment below.)
struct ReferenceEditDraft {
    var name = ""
    var parentCategoryId: Int? = nil
    var icon: String? = nil
    var accountType: String = "COURANT"
    /// v51 — voir `Account.excludedFromAggregates`.
    var excludedFromAggregates: Bool = false
}

/// Add/edit form for Compte/Catégorie, extracted from `ReferenceDataView`
/// into a DEDICATED View carrying its OWN `@State`.
///
/// ⚠️ Why this extraction is necessary (not just "cleaner"): on
/// macOS, an `.adaptivePane(isPresented:)` hosted at the root level (the
/// inspector, see `AdaptivePane.swift`) builds its content by calling the
/// `paneContent()` closure EXACTLY ONCE (`presentPane`), then freezes the result in an
/// `AnyView`. Anything computed INLINE in that closure from a
/// CALLING view's `@State` (e.g. `editDraftName` on `ReferenceDataView`) therefore
/// stayed frozen at its value at the moment the pane OPENED —
/// `confirmDisabled: editDraftName.isEmpty` stayed stuck at `true` (an empty name at
/// the moment "Add" was tapped) even after typing a name, because nothing ever
/// called that closure again. The "Save" button looked dead.
///
/// A `@State` DECLARED ON THIS VIEW, on the other hand, keeps triggering a
/// re-render of THIS view (so of `confirmDisabled`) on every keystroke — SwiftUI
/// tracks a child's identity/state independently of whether the parent that
/// built it is itself frozen. Rule of thumb: any dynamic `.paneChrome`/
/// `confirmDisabled` hosted in a macOS root pane must live in a dedicated
/// View with its OWN `@State`, never in an inline closure reading the
/// parent's `@State`.
///
/// ⚠️ No longer handles Payees (creating a payee must expose the SAME
/// rich fields as when editing — location, group,
/// type, note… — not a minimal name/regex/category form to fill in
/// afterward). `ReferenceDataView.startAdd()` now routes directly to
/// `PayeeDetailView(payee: nil, …)` for `selectedTab == .tiers`.
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

    /// Icon to show in the preview: reflects the icon ACTUALLY used for
    /// display (custom if set, otherwise the automatic fallback on the name).
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
                    // Only roots (with no parent) can be chosen as a parent
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
                                // Shows the icon ACTUALLY used — either the stored one,
                                // or the automatic fallback computed from the name.
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
