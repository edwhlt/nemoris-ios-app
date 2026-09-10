import SwiftUI

/// Platform-adaptive presentation, declared ONCE:
/// - **iOS / iPadOS**: native full-screen/detent `.sheet`.
/// - **macOS, level 1**: the content opens in the **right-hand side pane**,
///   which is the third column of `MainTabView`'s `NavigationSplitView`
///   (resizable, split toolbar — see `MainTabView.sidebarSplitView`).
/// - **macOS, level 2+** (a pane requested from content that's already in
///   the pane or in a sheet): a bounded `.sheet` — modals over a modal stay
///   modals.
///
/// > An earlier version presented an `.inspector` PER call site. Multiple
/// > `.inspector` instances CANNOT be stacked on the same view — macOS then
/// > rendered ALL of the panes' toolbars in the window bar at once (ghost
/// > Cancel/Save/Close buttons) and widened the window. The fix, still in
/// > effect, is the **single slot** `InspectorPaneCenter` owned by
/// > `MainTabView`: one active pane ⇒ one set of buttons ⇒ no more ghosts.
/// > Only the CONTAINER has changed since (`.inspector` → custom `HStack` →
/// > split view column).
///
/// A single switch point here means call sites carry no `#if os`.
///
/// ### Contract for presented views
/// - They keep their own `NavigationStack` + `.navigationTitle` + toolbar.
/// - They dismiss via `@Environment(\.paneDismiss)` (injected by the
///   wrapper, tied to ITS presentation). Equivalent to `\.dismiss` for a
///   sheet, but uniform regardless of the underlying implementation (sheet
///   OR inspector).
/// - Their sub-screens (pickers) stay nested `.sheet`s, or `.adaptivePane`s
///   that automatically fall back to a sheet via the `\.paneHostContext`
///   injected by the parent wrapper.

// MARK: - Environment: closing the adaptive pane

private struct PaneDismissKey: EnvironmentKey {
    // Computed (not `static let`): avoids the Swift 6 "static property
    // not concurrency-safe" error on a non-Sendable `() -> Void`. A fresh
    // no-op is returned when no pane has injected a dismiss closure.
    static var defaultValue: () -> Void { {} }
}

extension EnvironmentValues {
    /// Dismisses the current adaptive sheet/pane. Injected by `.adaptivePane`.
    var paneDismiss: () -> Void {
        get { self[PaneDismissKey.self] }
        set { self[PaneDismissKey.self] = newValue }
    }
}

// MARK: - Environment: host context (presentation depth)

/// Where the current view sits in the presentation hierarchy.
/// Determines whether an `.adaptivePane` requested here is level 1 (→
/// inspector on macOS) or level 2+ (→ stays a sheet).
enum PaneHostContext {
    /// At the window level (no modal above) — a pane opened here is level 1.
    case root
    /// Already inside a sheet — child panes stay sheets.
    case modal
    /// Already inside the macOS inspector — child panes become sheets.
    case inspector
}

private struct PaneHostContextKey: EnvironmentKey {
    static let defaultValue: PaneHostContext = .root
}

extension EnvironmentValues {
    var paneHostContext: PaneHostContext {
        get { self[PaneHostContextKey.self] }
        set { self[PaneHostContextKey.self] = newValue }
    }
}

// MARK: - PaneBarButton (cross-platform)

/// Descriptor for a pane-bar button. Used by the custom macOS chrome
/// (`PaneScaffold`) AND by `paneChrome` on iOS (mapped to `ToolbarItem`s) —
/// so it must live OUTSIDE the `#if os(macOS)` block. Pure struct, no AppKit
/// dependency.
struct PaneBarButton: Identifiable, Equatable {
    let id = UUID()
    let label: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var disabled: Bool = false
    /// Shows the title next to the icon (icon-only otherwise if `systemImage` is set).
    var showsTitle: Bool = true
    let action: () -> Void

    /// Manual conformance: `action` (a closure) isn't `Equatable`. Compares
    /// VISUAL state only — enough to drive `.onPreferenceChange` (detect a
    /// label/icon/`disabled` change between renders).
    static func == (lhs: PaneBarButton, rhs: PaneBarButton) -> Bool {
        lhs.label == rhs.label && lhs.systemImage == rhs.systemImage
            && lhs.role == rhs.role && lhs.disabled == rhs.disabled && lhs.showsTitle == rhs.showsTitle
    }
}

// MARK: - macOS sheet size

private extension View {
    /// Bounds the sheet on macOS for a comfortable size (no-op on iOS, where
    /// the sheet sizes itself natively). Only affects the sheet branch — the
    /// inspector's content is sized by `inspectorColumnWidth`.
    @ViewBuilder func adaptivePaneFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 640)
        #else
        self
        #endif
    }
}

#if os(macOS)

// MARK: - InspectorPaneCenter (macOS)

/// Single presentation slot for the global macOS inspector. Owned by
/// `MainTabView` (`@State`) and injected into the environment for the whole
/// layout — level-1 `.adaptivePane`s route their content here instead of
/// presenting a sheet.
///
/// Replacement semantics: presenting a pane while another is open replaces
/// the content and calls the previous one's `onDismiss` (resetting its call
/// site's binding). The old modifier's `onChange` then sees a different id
/// in the slot → no-op (no double dismissal).
/// The pane content PUBLISHES its own chrome (title + buttons) here, and
/// `MainTabView` renders it as real native `ToolbarItem`s in the system bar,
/// separated from the module's own tools. No custom bar is drawn inside the
/// pane itself.
struct PaneChromeModel: Equatable {
    var title: String
    /// Left button of the inspector group (Close / Cancel).
    var leading: PaneBarButton?
    /// Right-hand buttons (Delete, Edit / Save…), in visual order.
    var trailing: [PaneBarButton]
}

@Observable @MainActor
final class InspectorPaneCenter {
    struct Pane: Identifiable {
        /// RENDER identity: regenerated on every presentation (even from the
        /// same call site), so `.id(pane.id)` recreates the subtree and the
        /// content's `@State` (e.g. `MacEntityPane.current`) re-seeds with
        /// the new data. Without this, clicking a second row wouldn't change
        /// the detail shown.
        let id: UUID
        /// OWNER identity (call site): stable as long as the same
        /// `.adaptivePane` drives the pane. Used to de-duplicate dismissals.
        let ownerId: UUID
        let content: AnyView
        /// Resets the call site's binding (isPresented = false / item = nil).
        let onDismiss: () -> Void
    }

    private(set) var pane: Pane?

    /// Presents (or re-presents) a given call site's pane.
    /// - Same `ownerId` (re-presentation, e.g. a different row clicked):
    ///   replaces the content with a FRESH render `id`, without dismissing
    ///   (no onDismiss call).
    /// - Different `ownerId` (another screen opens a pane): dismisses the
    ///   previous one first (resetting ITS binding), then installs the new one.
    func present(ownerId: UUID, content: AnyView, onDismiss: @escaping () -> Void) {
        if let current = pane, current.ownerId != ownerId {
            current.onDismiss()
        }
        pane = Pane(id: UUID(), ownerId: ownerId, content: content, onDismiss: onDismiss)
    }

    /// Dismissal initiated by the inspector itself (close button, toggle,
    /// module switch): clears the slot, THEN resets the caller's binding.
    func dismissCurrent() {
        guard let current = pane else { return }
        pane = nil
        current.onDismiss()
    }

    /// Dismissal initiated by the call site (binding set to false/nil): the
    /// binding is already reset, this just clears the slot if it's still
    /// this pane.
    func dismissIfCurrent(_ ownerId: UUID) {
        guard pane?.ownerId == ownerId else { return }
        pane = nil
    }
}

// MARK: - Pane metrics (macOS)

/// Pane column widths (`MainTabView.inspectorColumn`), passed to
/// `.navigationSplitViewColumnWidth(min:ideal:max:)`. The user resizes by
/// dragging the divider; AppKit remembers the chosen width, so nothing needs
/// to be persisted here.
///
/// `min` must stay wide enough that the pane's `Form`s (label + field on one
/// line) don't break; `max` must stay bounded enough that the module column
/// remains usable on a laptop screen.
enum InspectorPaneMetrics {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 440
    /// Deliberately bounded: beyond this the pane would eat the window
    /// instead of leaving room for the module.
    static let maxWidth: CGFloat = 640
}

// MARK: - Pane chrome → system bar (macOS)

/// Declares the pane content's `.toolbar`, FROM that content.
///
/// On macOS any `.toolbar` in the tree bubbles up into the window's unified
/// bar: the pane posts its actions there like any other view, and they sit
/// alongside the module's own. Two reasons to do it HERE rather than routing
/// an action model up to `MainTabView`:
///
/// 1. **Freshness** — the closures belong to the CURRENT render of the
///    content. Routing chrome through an observable object re-read in a
///    distant `.toolbar` produced buttons frozen at their first render
///    (Close/Delete with no effect, `disabled` never re-evaluated): SwiftUI
///    doesn't reliably re-evaluate toolbar content on a plain observable
///    change.
/// 2. **Grouping** — the pane's items are a `ToolbarItemGroup` (native
///    grouping; `ControlGroup` rendered sometimes as a pill, sometimes as
///    separate buttons).
///
/// What visually separates the pane's actions from the module's is the split
/// view's column STRUCTURE (macOS inserts a tracking separator between the
/// toolbars of two columns). As long as the pane wasn't its own column, no
/// `ToolbarSpacer` dissociated the two groups — in either `.automatic` or
/// `.primaryAction` placement — they stayed bunched at the window's trailing
/// edge.
///
/// **Left-aligning the pane's actions is not achievable natively.**
/// `.primaryAction`, `.cancellationAction`+`.confirmationAction` separately,
/// and `.navigation` were all tried: the first two land identically — at the
/// TRAILING edge of the pane's segment (just before `.searchable`, if the
/// module has one). `.navigation` breaks column-scoping and puts the group
/// in the MODULE's segment instead (next to its own title), not the pane's.
/// There is no SwiftUI placement that renders a group LEADING in the segment
/// of a non-sidebar column of a `NavigationSplitView`.
private struct InspectorChromeToolbar: ViewModifier {
    let make: () -> PaneChromeModel

    func body(content: Content) -> some View {
        let chrome = make()
        return content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let leading = chrome.leading {
                    barButton(leading)
                }
                ForEach(chrome.trailing) { button in
                    barButton(button)
                }
            }
        }
    }

    /// Icon-only + tooltip WHEN an icon was provided; text label otherwise.
    ///
    /// Never invent a default icon for an action that doesn't declare one.
    /// Defaulting every confirmation button to a checkmark makes an action
    /// like "Accept all" (which bulk-creates detected recurring patterns)
    /// indistinguishable from a generic "OK/close" — a single tap can then
    /// trigger a bulk action the user only meant to dismiss. An explicit
    /// label is longer but unambiguous.
    @ViewBuilder
    private func barButton(_ button: PaneBarButton) -> some View {
        Button(role: button.role, action: button.action) {
            if let icon = button.systemImage {
                Image(systemName: icon)
            } else {
                // `LocalizedStringKey(...)`, jamais `Text(button.label)` :
                // `.label` est une `String` d'exécution, donc l'overload
                // verbatim — aucune traduction. Enveloppée, elle est résolue
                // par SwiftUI contre `\.locale`, donc traduite ET réactive.
                Text(LocalizedStringKey(button.label))
            }
        }
        .disabled(button.disabled)
        // `.help`/`.accessibilityLabel` pontent vers la chrome native et ne
        // consultent PAS `\.locale` — d'où les modificateurs dédiés.
        .localizedHelp(button.label)
        .localizedAccessibilityLabel(button.label)
        .tint(button.role == .destructive ? AppTheme.Colors.danger : AppTheme.Colors.accent)
    }
}

extension View {
    /// Declares this pane content's chrome (title + actions) in the macOS
    /// system bar. See `InspectorChromeToolbar`.
    func publishesInspectorChrome(_ make: @escaping () -> PaneChromeModel) -> some View {
        modifier(InspectorChromeToolbar(make: make))
    }
}

// MARK: - Modifiers de routage (macOS)

/// Boolean variant: routes to the global inspector at level 1, sheet otherwise.
private struct AdaptivePaneBoolModifier<PaneContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    /// Equivalent of `.sheet`'s `onDismiss:` — called when the pane closes,
    /// regardless of the path (binding, replacement, module switch).
    let onDismiss: (() -> Void)?
    @ViewBuilder let paneContent: () -> PaneContent

    @Environment(InspectorPaneCenter.self) private var center: InspectorPaneCenter?
    @Environment(\.paneHostContext) private var hostContext
    @State private var paneId = UUID()

    func body(content: Content) -> some View {
        if hostContext == .root, let center {
            content
                .onChange(of: isPresented) { _, newValue in
                    if newValue {
                        presentPane(center)
                    } else {
                        // Every dismissal path routes back through here (the
                        // center resets the binding) → a single call site for
                        // onDismiss.
                        center.dismissIfCurrent(paneId)
                        onDismiss?()
                    }
                }
                .onAppear {
                    // Binding already true at mount time (restored state,
                    // presentation scheduled before the view appears).
                    if isPresented { presentPane(center) }
                }
                // Closes the pane when THIS call site leaves the tree — a
                // back navigation, a module switch (`.id(selectedTab)`
                // unmounts the whole subtree), a NavigationStack pop.
                // Without this the pane would stay visible showing the
                // content of a screen that no longer exists: nothing in
                // `InspectorPaneCenter` is otherwise told that the view which
                // opened it just left, since the center is a separate object
                // owned by `MainTabView`, not by this view. `dismissIfCurrent`
                // rather than `dismissCurrent`: this view's binding is about
                // to be deallocated anyway, so there's no need to reset it via
                // `onDismiss` — only the center's slot needs clearing.
                .onDisappear { center.dismissIfCurrent(paneId) }
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                paneContent()
                    .environment(\.paneDismiss, { isPresented = false })
                    .environment(\.paneHostContext, .modal)
                    // ⚠️ Ré-injection EXPLICITE, obligatoire — bug réel confirmé
                    // par sonde le 2026-08-25 : une `.sheet()` macOS ouverte
                    // depuis le contenu de la colonne "detail" d'un
                    // `NavigationSplitView` n'hérite PAS de `\.locale` posé au
                    // niveau de la fenêtre, même remonté à la vraie racine du
                    // contenu. Cette sheet est une vraie `NSWindow` séparée sur
                    // macOS (contrairement à iOS, où elle partage la fenêtre) —
                    // son ancrage d'environnement semble ignorer tout ce qui est
                    // au-dessus d'un `NavigationSplitView`. `AppLocalization.locale`
                    // (lecture directe UserDefaults, pas de dépendance SwiftUI)
                    // donne la valeur correcte indépendamment de ce bug.
                    .environment(\.locale, AppLocalization.locale)
                    .adaptivePaneFrame()
                    // Même raison que `presentPane` ci-dessous : sans fond
                    // explicite, un `.sheet` macOS niveau 2+ (une pane ouverte
                    // depuis une pane déjà ouverte) laisse transparaître le
                    // matériau translucide par défaut de la fenêtre — le
                    // fond de bureau de l'utilisateur bleedait à travers
                    // (retour d'usage 2026-08-19). Seul le chemin racine
                    // (`presentPane`) l'avait ; ce chemin niveau 2+ ne
                    // l'avait jamais eu.
                    .background(AppTheme.Colors.background)
            }
        }
    }

    private func presentPane(_ center: InspectorPaneCenter) {
        center.present(
            ownerId: paneId,
            content: AnyView(
                paneContent()
                    .environment(\.paneDismiss, { isPresented = false })
                    .environment(\.paneHostContext, .inspector)
                    // Background painted BY THE HOST, not left to the
                    // content. Otherwise each view supplies (or forgets) its
                    // own, and the pane mismatches the module next to it
                    // depending on which screen is presented. Here it's
                    // uniform by construction.
                    .background(AppTheme.Colors.background)
            ),
            onDismiss: { isPresented = false }
        )
    }
}

/// `Identifiable?` variant: routes to the global inspector at level 1, sheet otherwise.
private struct AdaptivePaneItemModifier<Item: Identifiable, PaneContent: View>: ViewModifier {
    @Binding var item: Item?
    /// See AdaptivePaneBoolModifier.onDismiss.
    let onDismiss: (() -> Void)?
    @ViewBuilder let paneContent: (Item) -> PaneContent

    @Environment(InspectorPaneCenter.self) private var center: InspectorPaneCenter?
    @Environment(\.paneHostContext) private var hostContext
    @State private var paneId = UUID()

    func body(content: Content) -> some View {
        if hostContext == .root, let center {
            content
                .onChange(of: item?.id) { _, newId in
                    if newId != nil, let value = item {
                        // Presentation or re-presentation (item swapped live).
                        presentPane(center, value: value)
                    } else {
                        center.dismissIfCurrent(paneId)
                        onDismiss?()
                    }
                }
                .onAppear {
                    if let value = item { presentPane(center, value: value) }
                }
                // See AdaptivePaneBoolModifier — closes the pane when this
                // call site leaves the tree (back navigation, module switch).
                .onDisappear { center.dismissIfCurrent(paneId) }
        } else {
            content.sheet(item: $item, onDismiss: onDismiss) { value in
                paneContent(value)
                    .environment(\.paneDismiss, { item = nil })
                    .environment(\.paneHostContext, .modal)
                    // Cf. AdaptivePaneBoolModifier : ré-injection obligatoire,
                    // une `.sheet()` macOS niveau 2+ n'hérite pas de `\.locale`
                    // depuis un ancêtre au-dessus d'un `NavigationSplitView`.
                    .environment(\.locale, AppLocalization.locale)
                    .adaptivePaneFrame()
                    // Cf. AdaptivePaneBoolModifier : sans ce fond, un `.sheet`
                    // macOS niveau 2+ laisse transparaître le matériau
                    // translucide par défaut de la fenêtre.
                    .background(AppTheme.Colors.background)
            }
        }
    }

    private func presentPane(_ center: InspectorPaneCenter, value: Item) {
        center.present(
            ownerId: paneId,
            content: AnyView(
                paneContent(value)
                    .environment(\.paneDismiss, { item = nil })
                    .environment(\.paneHostContext, .inspector)
                    // Background painted BY THE HOST, not left to the
                    // content. Otherwise each view supplies (or forgets) its
                    // own, and the pane mismatches the module next to it
                    // depending on which screen is presented. Here it's
                    // uniform by construction.
                    .background(AppTheme.Colors.background)
            ),
            onDismiss: { item = nil }
        )
    }
}

#endif

// MARK: - Custom chrome for macOS sheets (level 2+)

/// Dessine la barre de titre + boutons d'une sheet macOS À LA MAIN, sans
/// `.navigationTitle`/`.toolbar` natif.
///
/// Root cause établie par capture d'écran EN DIRECT (retour d'usage
/// 2026-08-21) : la barre d'outils native d'une `.sheet` macOS (fenêtre
/// séparée) ET son bandeau de boutons bas (`.cancellationAction`/
/// `.confirmationAction`) sont des surfaces AppKit à matériau translucide
/// vibrant — `.toolbarBackground(Color, for: .windowToolbar)` COMPILE mais
/// n'a AUCUN effet visuel observable dessus (vérifié sur un build fraîchement
/// recompilé, pas seulement rapporté par l'utilisateur). Le fond d'écran de
/// l'utilisateur continue de transparaître au travers, en haut ET en bas.
///
/// Contrairement au niveau 1 (inspecteur, `publishesInspectorChrome`), qui
/// pose de VRAIS `ToolbarItem`s dans la barre système de `MainTabView` (une
/// surface qui, elle, n'a jamais montré ce bug), une sheet de niveau 2+ est
/// une fenêtre à part entière sans ce filet. Remède : ne plus jamais confier
/// le titre/les boutons d'une sheet macOS à `.toolbar` — les dessiner en
/// SwiftUI ordinaire, dont le compositing (`.background()`) fonctionne
/// normalement (déjà prouvé par `.scrollContentBackground(.hidden)` sur les
/// `List`, une classe de bug voisine).
#if os(macOS)
/// Non-`private` : réutilisé directement par `ImportEntryView`, qui a besoin
/// d'appliquer cette chrome à UN SEUL de ses multiples cas de présentation
/// (embarqué / inspecteur / sheet niveau 2) sans passer par le `.paneChrome`
/// générique, qui ne modélise pas son axe `isEmbedded` additionnel.
struct MacSheetTopBar: View {
    @Environment(\.locale) private var locale
    
    let title: String
    let cancel: PaneBarButton?

    var body: some View {
        return HStack {
            if let cancel {
                Button(action: cancel.action) {
                    Image(systemName: cancel.systemImage ?? "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .localizedHelp(cancel.label)
            }
            Spacer()
            // `title`/`.label` sont des `String` d'exécution — `Text(String)`
            // est l'overload verbatim, sans aucun lookup. Enveloppé en
            // `LocalizedStringKey`, SwiftUI résout contre `\.locale`, donc
            // traduit ET réactif au picker de langue. Un titre dynamique (nom
            // de compte, de position) n'est pas une clé de table : il retombe
            // simplement sur lui-même, l'enveloppe est sans risque.
            //
            // ⚠️ `LocalizedStringKey`, PAS `LocalizedStringResource` : ce
            // dernier porte sa propre locale et court-circuite l'environnement.
            Text(LocalizedStringKey(title))
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
            // Espaceur symétrique : centre visuellement le titre quand un
            // bouton "Annuler" occupe le côté gauche.
            if cancel != nil {
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.background)
    }
}

struct MacSheetBottomBar: View {
    let destructive: PaneBarButton?
    let confirm: PaneBarButton?

    var body: some View {
        HStack {
            if let destructive {
                Button(role: .destructive, action: destructive.action) {
                    Label(LocalizedStringKey(destructive.label), systemImage: destructive.systemImage ?? "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.danger)
            }
            Spacer()
            if let confirm {
                Button(LocalizedStringKey(confirm.label), action: confirm.action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Colors.accent)
                    .disabled(confirm.disabled)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.background)
    }
}

/// Assemble le contenu entre les deux barres dessinées à la main. Partagé
/// par `PaneChromeModifier` et `PaneChromeInlineModifier` — les deux
/// variantes macOS-sheet doivent rester visuellement identiques.
@MainActor
func macSheetChrome<Content: View>(
    title: String,
    cancel: PaneBarButton?,
    destructive: PaneBarButton?,
    confirm: PaneBarButton?,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(spacing: 0) {
        MacSheetTopBar(title: title, cancel: cancel)
        Divider()
        content()
        if destructive != nil || confirm != nil {
            Divider()
            MacSheetBottomBar(destructive: destructive, confirm: confirm)
        }
    }
    .background(AppTheme.Colors.background)
}

/// Champ de recherche dessiné à la main, pour macOS uniquement.
///
/// `.searchable(text:)` bridge vers un `NSSearchToolbarItem` NATIF — une
/// troisième surface AppKit, DISTINCTE de `.navigationTitle`/`.toolbar` (déjà
/// neutralisés par `macSheetChrome`), qui continue de laisser transparaître
/// le matériau translucide de la fenêtre même après leur suppression
/// (confirmé par capture d'écran en direct : la bande du champ de recherche
/// restait cuivrée alors que le titre et les boutons, eux, étaient corrigés
/// — retour d'usage 2026-08-21). Remède identique : ne plus utiliser
/// `.searchable` sur macOS pour une sheet, dessiner le champ nous-mêmes.
private struct MacInlineSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.Colors.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.xs)
        .background(AppTheme.Colors.background)
    }
}
#endif

extension View {
    /// `.searchable` sur iOS ; sur macOS, un champ dessiné à la main placé
    /// AU-DESSUS du contenu (cf. `MacInlineSearchField`) — jamais le
    /// `.searchable` natif, dont la barre reste cuivrée même une fois
    /// `.navigationTitle`/`.toolbar` neutralisés.
    ///
    /// Pas de paramètre `placement:` : certains cas (`.navigationBarDrawer`)
    /// n'existent que côté iOS dans `SearchFieldPlacement` — un paramètre
    /// non gardé casserait la compilation macOS au premier appel qui s'en
    /// sert. `.automatic` partout est un compromis assumé (perte mineure :
    /// le champ peut se cacher au scroll sur iOS au lieu de rester "always").
    @ViewBuilder
    func paneSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            MacInlineSearchField(text: text, prompt: prompt)
            self
        }
        #else
        self.searchable(text: text, prompt: prompt)
        #endif
    }
}

// MARK: - EntityDetailEditPane (cross-platform): read-only detail ⇄ edit

/// "Entity" container for an EXISTING record, on **iOS and macOS**: tapping
/// first opens a **read-only detail** (Close / Delete / Edit), then "Edit"
/// switches to the existing edit form (Cancel / Save). BOTH exit paths from
/// the form (Cancel and post-save) return to the detail: the injected
/// `\.paneDismiss` re-fetches the item via `refresh` — so the detail is
/// up to date after a save, and a visual no-op after a cancel.
///
/// The detail's `.paneChrome` already adapts to platform/context (macOS
/// level-1 system bar, native `NavigationStack`+toolbar for iOS/sheet) — so
/// this container has NOTHING macOS-specific of its own.
private struct EntityDetailEditPane<Item, DetailContent: View, EditContent: View>: View {
    let title: String
    /// Fresh re-fetch from the repository (never from a captured array).
    /// nil = the item no longer exists (deleted elsewhere) → keep the snapshot.
    let refresh: (Item) -> Item?
    /// Routes to the parent's existing delete flow (list's confirmationDialog,
    /// etc.). The pane closes immediately after.
    let onDelete: (Item) -> Void
    @ViewBuilder let detail: (Item) -> DetailContent
    @ViewBuilder let editContent: (Item) -> EditContent

    @State private var current: Item
    @State private var isEditing = false
    @Environment(\.paneDismiss) private var paneDismiss

    init(
        title: String,
        item: Item,
        refresh: @escaping (Item) -> Item?,
        onDelete: @escaping (Item) -> Void,
        @ViewBuilder detail: @escaping (Item) -> DetailContent,
        @ViewBuilder editContent: @escaping (Item) -> EditContent
    ) {
        self.title = title
        self.refresh = refresh
        self.onDelete = onDelete
        self.detail = detail
        self.editContent = editContent
        _current = State(initialValue: item)
    }

    var body: some View {
        if isEditing {
            // The form publishes ITS OWN chrome (Cancel / Save) via
            // `.paneChrome`. Both Cancel and post-save dismiss return to
            // the detail.
            editContent(current)
                .environment(\.paneDismiss, endEditing)
        } else {
            detail(current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paneChrome(
                    title,
                    cancelLabel: "Fermer", onCancel: { paneDismiss() },
                    destructiveLabel: "Supprimer", onDestructive: {
                        onDelete(current)
                        paneDismiss()
                    },
                    confirmLabel: "Modifier", confirmIcon: "pencil", onConfirm: { isEditing = true }
                )
        }
    }

    private func endEditing() {
        current = refresh(current) ?? current
        isEditing = false
    }
}

// MARK: - paneChrome: adaptive form/screen chrome

/// Replaces the `NavigationStack { … }.toolbar { Cancel / Save }` pair used
/// by forms and screens presented in a pane/sheet:
/// - **iOS**, and **macOS level 2** (sheet, separate window): native
///   `NavigationStack` + `.toolbar` (historical behavior, rendered in the sheet).
/// - **macOS level 1** (inspector): the content renders BARE and publishes
///   its own chrome (Cancel / Save) to the system bar.
private struct PaneChromeModifier: ViewModifier {
    let title: String
    let cancel: PaneBarButton?
    /// Optional destructive button (e.g. Delete), rendered BEFORE `confirm`
    /// in the trailing group — for detail screens (Close / Delete / Edit).
    let destructive: PaneBarButton?
    let confirm: PaneBarButton?

    #if os(macOS)
    @Environment(\.paneHostContext) private var host
    #endif

    private var trailing: [PaneBarButton] {
        [destructive, confirm].compactMap { $0 }
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        if host == .inspector {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .publishesInspectorChrome {
                    PaneChromeModel(title: title, leading: cancel, trailing: trailing)
                }
        } else {
            macSheetChrome(title: title, cancel: cancel, destructive: destructive, confirm: confirm) {
                content
            }
        }
        #else
        navStack(content)
        #endif
    }

    #if !os(macOS)
    @ViewBuilder
    private func navStack(_ content: Content) -> some View {
        // `title`/`.label` are runtime Strings — `.navigationTitle(String)`/
        // `Button(String, action:)` hit the StringProtocol overload, which
        // never does a Localizable.strings lookup. Dynamic titles (account/
        // position names) aren't table keys, so the wrap is a no-op for them.
        NavigationStack {
            content
                .localizedNavigationTitle(title)
                .toolbar {
                    if let cancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(LocalizedStringKey(cancel.label), action: cancel.action)
                        }
                    }
                    if let destructive {
                        ToolbarItem(placement: .destructiveAction) {
                            Button(role: .destructive, action: destructive.action) {
                                Label(LocalizedStringKey(destructive.label), systemImage: destructive.systemImage ?? "trash")
                            }
                        }
                    }
                    if let confirm {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(LocalizedStringKey(confirm.label), action: confirm.action)
                                .disabled(confirm.disabled)
                        }
                    }
                }
        }
    }
    #endif
}

extension View {
    /// Adaptive chrome for a form/screen (see `PaneChromeModifier`).
    /// Apply to the CONTENT (Form/ScrollView) WITHOUT its own
    /// `NavigationStack` or `.toolbar` — this modifier supplies them based
    /// on platform/context.
    /// `destructiveLabel`/`onDestructive`: optional Delete button (detail
    /// screens: Close / Delete / Edit).
    ///
    /// `confirmIcon`: SF Symbol for the confirmation button in the macOS
    /// pane (cancellation is ALWAYS "xmark" — unambiguous, since Close/Cancel
    /// never mean anything other than leaving without acting). No icon is
    /// guessed from the label: on iOS and in macOS sheets the button stays
    /// native text either way (`Button(confirm.label, …)`, see `navStack`),
    /// so `confirmIcon` changes NOTHING outside the macOS pane — leaving it
    /// `nil` keeps the text there too (see the warning in
    /// `InspectorChromeToolbar.barButton`: never invent an icon for an
    /// action that doesn't explicitly declare one).
    func paneChrome(
        _ title: String,
        cancelLabel: String? = nil,
        onCancel: (() -> Void)? = nil,
        destructiveLabel: String? = nil,
        onDestructive: (() -> Void)? = nil,
        confirmLabel: String? = nil,
        confirmIcon: String? = nil,
        confirmDisabled: Bool = false,
        onConfirm: (() -> Void)? = nil
    ) -> some View {
        modifier(PaneChromeModifier(
            title: title,
            cancel: (cancelLabel != nil && onCancel != nil)
                ? PaneBarButton(label: cancelLabel!, systemImage: "xmark", showsTitle: false, action: onCancel!)
                : nil,
            destructive: (destructiveLabel != nil && onDestructive != nil)
                ? PaneBarButton(label: destructiveLabel!, systemImage: "trash", role: .destructive, showsTitle: false, action: onDestructive!)
                : nil,
            confirm: (confirmLabel != nil && onConfirm != nil)
                ? PaneBarButton(label: confirmLabel!, systemImage: confirmIcon, disabled: confirmDisabled, showsTitle: confirmIcon == nil, action: onConfirm!)
                : nil
        ))
    }
}

// MARK: - paneChromeInline: variant for content with internal push navigation

/// Variant of `.paneChrome` for content that NEEDS to keep its OWN
/// `NavigationStack` (because it contains an internal `NavigationLink`/push —
/// pushing from the macOS pane without a local `NavigationStack` has no
/// reliable navigation context). Apply directly INSIDE that
/// `NavigationStack`, at the same level as `.navigationTitle`/`.toolbar`
/// (NOT outside it — a `.toolbar` placed outside a `NavigationStack` doesn't
/// attach to anything and disappears silently).
///
/// - iOS, and macOS level 2 (sheet): native `.navigationTitle` + `.toolbar`,
///   exactly like the historical pattern — the local `NavigationStack`
///   displays them normally.
/// - macOS level 1 (inspector): NO `.navigationTitle`/`.toolbar` posted here
///   (the local `NavigationStack` stays, bare, so the internal push works);
///   the chrome is published separately to the system bar.
private struct PaneChromeInlineModifier: ViewModifier {
    let title: String
    let cancel: PaneBarButton?
    let confirm: PaneBarButton?

    #if os(macOS)
    @Environment(\.paneHostContext) private var host
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        if host == .inspector {
            content.publishesInspectorChrome {
                PaneChromeModel(title: title, leading: cancel, trailing: confirm.map { [$0] } ?? [])
            }
        } else {
            // Cf. PaneChromeModifier.macSheetChrome : le contenu conserve SA
            // PROPRE `NavigationStack` interne (pour son push), on l'enrobe
            // juste des barres dessinées à la main au lieu de lui laisser
            // poser un `.navigationTitle`/`.toolbar` natif inefficace sur
            // macOS-sheet.
            macSheetChrome(title: title, cancel: cancel, destructive: nil, confirm: confirm) {
                content
            }
        }
        #else
        nativeChrome(content)
        #endif
    }

    #if !os(macOS)
    @ViewBuilder
    private func nativeChrome(_ content: Content) -> some View {
        // Same wrap as PaneChromeModifier.navStack — see its comment.
        content
            .localizedNavigationTitle(title)
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LocalizedStringKey(cancel.label), action: cancel.action)
                    }
                }
                if let confirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LocalizedStringKey(confirm.label), action: confirm.action)
                            .disabled(confirm.disabled)
                    }
                }
            }
    }
    #endif
}

extension View {
    /// See `PaneChromeInlineModifier`. Apply INSIDE the existing
    /// `NavigationStack` (on its content), never outside it. `confirmIcon`:
    /// see `paneChrome` — only applies to the macOS pane, `nil` keeps the text.
    func paneChromeInline(
        _ title: String,
        cancelLabel: String? = nil,
        onCancel: (() -> Void)? = nil,
        confirmLabel: String? = nil,
        confirmIcon: String? = nil,
        confirmDisabled: Bool = false,
        onConfirm: (() -> Void)? = nil
    ) -> some View {
        modifier(PaneChromeInlineModifier(
            title: title,
            cancel: (cancelLabel != nil && onCancel != nil)
                ? PaneBarButton(label: cancelLabel!, systemImage: "xmark", showsTitle: false, action: onCancel!)
                : nil,
            confirm: (confirmLabel != nil && onConfirm != nil)
                ? PaneBarButton(label: confirmLabel!, systemImage: confirmIcon, disabled: confirmDisabled, showsTitle: confirmIcon == nil, action: onConfirm!)
                : nil
        ))
    }
}

// MARK: - PaneToggleButton: toggle-style trigger button

/// Toolbar button that OPENS an `.adaptivePane`, with TOGGLE semantics
/// rather than plain opening: tapping again WHILE its pane is showing closes
/// it, exactly like the pane's own Close button.
///
/// Driving the `Toggle` from the SAME `Binding<Bool>` passed to
/// `.adaptivePane(isPresented:)` is what makes the rest come for free:
/// - **Close on re-tap**: `Toggle` flips its binding to `false` on tap,
///   which `AdaptivePaneBoolModifier.onChange(of: isPresented)` already
///   handles like any other dismissal (slot dismiss + `onDismiss`).
/// - **Turns back "off" if the pane's content changes underneath it**: when
///   ANOTHER `.adaptivePane` takes the slot (e.g. the user clicks a
///   different row while this pane is open), `InspectorPaneCenter.present`
///   calls the previous owner's `onDismiss` — which flips ITS binding to
///   `false`. The toggle, bound to that same value, releases itself.
/// - **Turns back "off" on back navigation**: `.onDisappear` (see
///   `AdaptivePaneBoolModifier`) clears the slot when the triggering view
///   disappears; nothing extra needed here either.
///
/// On iOS (`.adaptivePane` → `.sheet`), `isOn` directly drives the sheet's
/// `isPresented` — tapping the icon again while the sheet is showing closes
/// it too, consistent with the macOS behavior.
struct PaneToggleButton: View {
    let label: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        // `label` est une `String` d'exécution (libellés littéraux comme
        // "Tags", et texte dynamique sur certains sites) — `Label(String, …)`
        // est l'overload verbatim, sans lookup, contrairement à
        // `Label(LocalizedStringKey, …)` qui résout contre `\.locale` et suit
        // donc le picker de langue.
        Toggle(isOn: $isOn) {
            Label(LocalizedStringKey(label), systemImage: systemImage)
        }
        .toggleStyle(.button)
        // `.toggleStyle(.button)` without an explicit `.tint` inherits the
        // ambient `.tint(AppTheme.Colors.accent)` set on `MainTabView` — so
        // it's accent-colored even in the OFF state (standard iOS behavior
        // for a bordered togglable button, independent of `isOn`). Harmless
        // in isolation, but next to toolbar icons that explicitly force
        // `AppTheme.Colors.textSecondary`, a button in this state can read
        // as "active" when nothing is open. The tint now follows `isOn`.
        .tint(isOn ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
        .localizedHelp(label)
        .localizedAccessibilityLabel(label)
    }
}

// MARK: - API publique

extension View {
    /// macOS "detail" tap: opens the detail pane when a row is clicked.
    /// No-op on iOS, where rows keep their historical behavior (swipe to
    /// edit/delete, no tap).
    @ViewBuilder
    func macDetailTap(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onTapGesture(perform: action)
        #else
        self
        #endif
    }

    /// "Entity" pane for an EXISTING record, UNIFIED across iOS + macOS: tap
    /// opens a read-only detail (Close / Delete / Edit) → "Edit" switches to
    /// `edit` (Cancel / Save) → returns to the refreshed detail via
    /// `refresh`. On macOS level 1, the detail lives in the side pane; on
    /// iOS (and macOS level 2), in a sheet — same logic, adapted presentation.
    /// - `onDelete` must route to the parent's existing delete flow.
    @ViewBuilder
    func adaptiveEntityPane<Item: Identifiable, DetailContent: View, EditContent: View>(
        item: Binding<Item?>,
        title: String,
        refresh: @escaping (Item) -> Item?,
        onDelete: @escaping (Item) -> Void,
        @ViewBuilder detail: @escaping (Item) -> DetailContent,
        @ViewBuilder edit: @escaping (Item) -> EditContent
    ) -> some View {
        adaptivePane(item: item) { value in
            EntityDetailEditPane(
                title: title, item: value, refresh: refresh, onDelete: onDelete,
                detail: detail, editContent: edit
            )
        }
    }

    /// Presents `content` driven by a boolean: global inspector on macOS at
    /// level 1, sheet everywhere else.
    @ViewBuilder
    func adaptivePane<PaneContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> PaneContent
    ) -> some View {
        #if os(macOS)
        modifier(AdaptivePaneBoolModifier(isPresented: isPresented, onDismiss: onDismiss, paneContent: content))
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content()
                .environment(\.paneDismiss, { isPresented.wrappedValue = false })
                .environment(\.paneHostContext, .modal)
                .adaptivePaneFrame()
        }
        #endif
    }

    /// Variant driven by an `Identifiable?` (equivalent of `.sheet(item:)`).
    @ViewBuilder
    func adaptivePane<Item: Identifiable, PaneContent: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> PaneContent
    ) -> some View {
        #if os(macOS)
        modifier(AdaptivePaneItemModifier(item: item, onDismiss: onDismiss, paneContent: content))
        #else
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value)
                .environment(\.paneDismiss, { item.wrappedValue = nil })
                .environment(\.paneHostContext, .modal)
                .adaptivePaneFrame()
        }
        #endif
    }
}
