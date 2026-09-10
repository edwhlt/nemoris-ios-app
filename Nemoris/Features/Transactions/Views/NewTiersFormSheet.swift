import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct NewTiersFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prefilledName: String
    let prefilledRegex: String
    let allCategories: [Category]
    let onCreate: (String, String, Int?) -> Void  // name, regex, categoryId

    @State private var name: String
    @State private var regex: String
    @State private var categoryId: Int?

    init(prefilledName: String, prefilledRegex: String = "", allCategories: [Category],
         onCreate: @escaping (String, String, Int?) -> Void) {
        self.prefilledName = prefilledName
        self.prefilledRegex = prefilledRegex
        self.allCategories = allCategories
        self.onCreate = onCreate
        _name = State(initialValue: prefilledName)
        _regex = State(initialValue: prefilledRegex)
        _categoryId = State(initialValue: nil)
    }

    var body: some View {
            Form {
                Section {
                    TextField("Nom", text: $name).autocorrectionDisabled()
                }
                Section("Regex de détection (optionnel)") {
                    TextEditor(text: $regex)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }
                Section("Catégorie par défaut") {
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Non catégorisé").tag(Int?.none)
                        ForEach(allCategories) { c in
                            Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .nemorisFormStyle()
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // barre d'outils native laisse le bureau de l'utilisateur
            // transparaître (retour d'usage 2026-08-21). Cf. le commentaire
            // de `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome(
                "Nouveau tiers",
                cancelLabel: "Annuler", onCancel: { dismiss() },
                confirmLabel: "Confirmer",
                confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                onConfirm: {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    onCreate(n, regex.trimmingCharacters(in: .whitespaces), categoryId)
                    dismiss()
                }
            )
    }
}
