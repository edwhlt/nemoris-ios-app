import SwiftUI
#if canImport(UIKit)
import ContactsUI
#endif

/// SwiftUI wrapper around `CNContactPickerViewController` (UIKit).
/// Shows the standard iOS contacts book, the user picks one, and its
/// `CNContact.identifier` + formatted name are returned to the parent via
/// the callback.
///
/// Usage:
///     .sheet(isPresented: $show) {
///         ContactPickerSheet { contact in
///             tier.contactIdentifier = contact.identifier
///             tier.name = contact.name
///         }
///     }
#if os(macOS)
/// macOS: `CNContactPickerViewController` (ContactsUI) does not exist on
/// Mac. `CNContactStore` itself is available, so a custom AppKit/SwiftUI
/// picker could be built later — for now, an explicit message is shown
/// instead of a button that does nothing.
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

    /// Callback invoked when the user picks a contact (or nil on cancel).
    /// The sheet closes automatically afterward.
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
