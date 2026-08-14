import SwiftUI
#if canImport(UIKit)
import ContactsUI
#endif

/// Wrapper SwiftUI autour de `CNContactPickerViewController` (UIKit).
/// Affiche le carnet de contacts iOS standard, l'utilisateur en choisit un,
/// on renvoie son `CNContact.identifier` + nom formaté au parent via le callback.
///
/// Utilisation :
///     .sheet(isPresented: $show) {
///         ContactPickerSheet { contact in
///             tier.contactIdentifier = contact.identifier
///             tier.name = contact.name
///         }
///     }
#if os(macOS)
/// macOS : `CNContactPickerViewController` (ContactsUI) n'existe pas sur Mac.
/// N.1 écrira un picker custom AppKit/SwiftUI (CNContactStore est dispo) —
/// en attendant, message explicite plutôt qu'un bouton qui ne fait rien.
struct ContactPickerSheet: View {

    struct PickedContact {
        let identifier: String
        let name: String
    }

    let onPick: (PickedContact?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                icon: "person.crop.circle.badge.clock",
                title: "Bientôt sur Mac",
                message: "Le choix d'un contact du carnet arrive dans une prochaine version Mac. En attendant, liez vos contacts depuis l'iPhone — la synchronisation iCloud propage le lien."
            )
            Button("Fermer") { onPick(nil); dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(minWidth: 380, minHeight: 300)
    }
}
#else
struct ContactPickerSheet: UIViewControllerRepresentable {

    struct PickedContact {
        let identifier: String
        let name: String
    }

    /// Callback appelé quand l'utilisateur pick un contact (ou nil si annule).
    /// La sheet se ferme automatiquement après.
    let onPick: (PickedContact?) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (PickedContact?) -> Void
        init(onPick: @escaping (PickedContact?) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.givenName
            onPick(PickedContact(identifier: contact.identifier, name: name))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onPick(nil)
        }
    }
}
#endif
