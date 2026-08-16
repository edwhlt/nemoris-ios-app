import SwiftUI

// Native macOS port.
//
// Compatibility layer: reproduces, on macOS, the signatures of iOS-only APIs
// used across ~47 views (as either a no-op or an AppKit equivalent), so the
// shared SwiftUI code compiles AS-IS on both platforms without scattering
// 150 `#if os(iOS)` blocks across the views.
//
// Rules:
//   • Same name, same dotted syntax at call sites (local shim enums).
//   • no-op when the concept doesn't exist on Mac (software keyboard,
//     autocapitalization, sheet detents…).
//   • semantic mapping when an equivalent exists (toolbar placements).
//
// ⚠️ File compiled ONLY on macOS (everything is under #if os(macOS)) — no
// impact on iOS builds.

#if os(macOS)
import AppKit

// MARK: - UIKit → AppKit bridges

/// Shared files use UIImage/UIColor/UIFont: on macOS these map to the
/// equivalent AppKit classes. Missing APIs are filled in below.
typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIFont = NSFont

extension NSColor {
    /// Equivalents of the UIKit semantic colors used in the shared code.
    static var label: NSColor { .labelColor }
    static var secondarySystemBackground: NSColor { .windowBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
}

extension NSImage {
    /// Equivalent of the UIImage.cgImage property (Vision OCR, logos).
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

extension Image {
    /// Lets `Image(uiImage:)` call sites compile unchanged.
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension Color {
    /// Lets `Color(uiColor:)` call sites compile unchanged.
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

extension NSImage {
    /// Equivalent of UIImage.pngData() (used by the logo cache).
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Equivalent of UIImage.jpegData(compressionQuality:).
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

// MARK: - iOS-only navigation modifiers → no-op

enum NavigationBarTitleDisplayModeShim { case automatic, inline, large }

extension View {
    /// iOS-only: the macOS title bar has no equivalent concept.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayModeShim) -> some View { self }
}

// MARK: - iOS-only text input → no-op (no software keyboard on Mac)

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

// NB: presentationDetents / presentationDragIndicator exist natively on
// macOS 13.3+ — no shim (one would create ambiguity).

// MARK: - iOS-only list styles

extension ListStyle where Self == InsetListStyle {
    /// iOS-only: mapped to .inset, the closest visual match on Mac.
    static var insetGrouped: InsetListStyle { InsetListStyle() }
}

// MARK: - iOS-only TabView paging

enum PageIndexDisplayModeShim { case automatic, always, never }

extension TabViewStyle where Self == DefaultTabViewStyle {
    /// iOS-only (.page): the default TabView is fine on Mac — horizontal
    /// page-swiping has no trackpad equivalent anyway.
    static func page(indexDisplayMode: PageIndexDisplayModeShim) -> DefaultTabViewStyle { DefaultTabViewStyle() }
}

// MARK: - iOS toolbar placements → semantic macOS equivalents

extension ToolbarItemPlacement {
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

// MARK: - iOS-only searchable placement

enum SearchFieldDisplayModeShim { case always, automatic }

extension SearchFieldPlacement {
    /// iOS-only: on Mac the search field lives in the toolbar.
    static func navigationBarDrawer(displayMode: SearchFieldDisplayModeShim) -> SearchFieldPlacement { .automatic }
    static var navigationBarDrawer: SearchFieldPlacement { .automatic }
}

// MARK: - Clipboard

/// Minimal facade compatible with `UIPasteboard.general.string = …` call
/// sites. Stateless struct (Sendable) — everything goes through
/// NSPasteboard.general.
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
