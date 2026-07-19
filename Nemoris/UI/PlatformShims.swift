import SwiftUI

// AXE N — Port macOS natif.
//
// Couche de compatibilité : reproduit côté macOS les signatures des APIs
// iOS-only utilisées dans ~47 vues (no-op ou équivalent AppKit), pour que le
// code SwiftUI partagé compile TEL QUEL sur les deux plateformes sans
// saupoudrer 150 `#if os(iOS)` dans les vues.
//
// Règles :
//   • Même nom, même syntaxe pointée aux call sites (enums shim locaux).
//   • no-op quand le concept n'existe pas sur Mac (clavier logiciel,
//     autocapitalisation, detents de sheet…).
//   • mapping sémantique quand un équivalent existe (placements toolbar).
//
// ⚠️ Fichier compilé UNIQUEMENT côté macOS (tout est sous #if os(macOS)) —
// aucun impact sur les builds iOS.

#if os(macOS)
import AppKit

// MARK: - Ponts UIKit → AppKit

/// Les fichiers partagés utilisent UIImage/UIColor/UIFont : sur macOS ce sont
/// les classes AppKit équivalentes. Les APIs manquantes sont comblées ci-dessous.
typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIFont = NSFont

extension NSColor {
    /// Équivalents des couleurs sémantiques UIKit utilisées dans le code partagé.
    static var label: NSColor { .labelColor }
    static var secondarySystemBackground: NSColor { .windowBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
}

extension NSImage {
    /// Équivalent de la propriété UIImage.cgImage (Vision OCR, logos).
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

extension Image {
    /// Permet aux call sites `Image(uiImage:)` de compiler tels quels.
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension Color {
    /// Permet aux call sites `Color(uiColor:)` de compiler tels quels.
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

extension NSImage {
    /// Équivalent de UIImage.pngData() (utilisé par le cache logos).
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Équivalent de UIImage.jpegData(compressionQuality:).
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

// MARK: - Modifiers de navigation iOS-only → no-op

enum NavigationBarTitleDisplayModeShim { case automatic, inline, large }

extension View {
    /// iOS-only : la barre de titre macOS n'a pas ce concept.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayModeShim) -> some View { self }
}

// MARK: - Saisie texte iOS-only → no-op (pas de clavier logiciel sur Mac)

enum KeyboardTypeShim {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad,
         phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch,
         asciiCapableNumberPad
}

enum TextInputAutocapitalizationShim { case never, words, sentences, characters }

extension View {
    func keyboardType(_ type: KeyboardTypeShim) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalizationShim?) -> some View { self }
}

// NB : presentationDetents / presentationDragIndicator existent nativement
// sur macOS 13.3+ — pas de shim (il créerait une ambiguïté).

// MARK: - Styles de liste iOS-only

extension ListStyle where Self == InsetListStyle {
    /// iOS-only : mappé sur .inset, le plus proche visuellement sur Mac.
    static var insetGrouped: InsetListStyle { InsetListStyle() }
}

// MARK: - TabView paging iOS-only

enum PageIndexDisplayModeShim { case automatic, always, never }

extension TabViewStyle where Self == DefaultTabViewStyle {
    /// iOS-only (.page) : sur Mac le TabView par défaut fait l'affaire — le
    /// swipe horizontal de pages n'existe pas au trackpad de toute façon.
    static func page(indexDisplayMode: PageIndexDisplayModeShim) -> DefaultTabViewStyle { DefaultTabViewStyle() }
}

// MARK: - Placements toolbar iOS → équivalents sémantiques macOS

extension ToolbarItemPlacement {
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

// MARK: - Placement searchable iOS-only

enum SearchFieldDisplayModeShim { case always, automatic }

extension SearchFieldPlacement {
    /// iOS-only : sur Mac le champ de recherche vit dans la toolbar.
    static func navigationBarDrawer(displayMode: SearchFieldDisplayModeShim) -> SearchFieldPlacement { .automatic }
    static var navigationBarDrawer: SearchFieldPlacement { .automatic }
}

// MARK: - Presse-papiers

/// Façade minimale compatible avec les call sites `UIPasteboard.general.string = …`.
/// Struct sans état (Sendable) — tout passe par NSPasteboard.general.
struct UIPasteboard: Sendable {
    static let general = UIPasteboard()

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        nonmutating set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

#endif
