import SwiftUI

/// Présentation adaptative selon la plateforme, déclarée UNE fois :
/// - **iOS / iPadOS** : `.sheet` plein écran/detent natif (comportement historique).
/// - **macOS, niveau 1** : le contenu s'ouvre dans **l'inspecteur global** à droite
///   (panneau latéral desktop, un seul `.inspector` attaché dans `MainTabView`).
/// - **macOS, niveau 2+** (pane demandé depuis un contenu déjà dans l'inspecteur ou
///   dans une sheet) : `.sheet` bornée — les modals par-dessus un modal restent des
///   modals.
///
/// > Historique : une première version présentait un `.inspector` PAR call site.
/// > Abandonné : on ne peut PAS empiler plusieurs `.inspector` sur une même vue —
/// > macOS rendait alors TOUTES les toolbars des panneaux dans la barre de fenêtre
/// > en même temps (boutons Cancel/Save/Close fantômes) et élargissait la fenêtre.
/// > La V2 (actuelle) corrige la cause racine : UN SEUL `.inspector` global dans
/// > `MainTabView`, dont le contenu est switché par `InspectorPaneCenter`. Un seul
/// > pane actif ⇒ un seul jeu de boutons ⇒ plus de fantômes.
///
/// Un seul point de bascule ici → les call sites n'ont aucun `#if os`.
///
/// ### Contrat pour les vues présentées
/// - Elles gardent leur `NavigationStack` + `.navigationTitle` + toolbar.
/// - Elles ferment via `@Environment(\.paneDismiss)` (injecté par le wrapper,
///   lié à SA présentation). Équivalent à `\.dismiss` pour une sheet, mais
///   uniforme quelle que soit l'implémentation (sheet OU inspecteur).
/// - Leurs sous-écrans (pickers) restent des `.sheet` imbriquées, ou des
///   `.adaptivePane` qui retombent automatiquement en sheet grâce au contexte
///   `\.paneHostContext` injecté par le wrapper parent.

// MARK: - Environnement : fermeture du panneau adaptatif

private struct PaneDismissKey: EnvironmentKey {
    // Computed (pas de `static let`) : évite l'erreur Swift 6 "static property
    // not concurrency-safe" sur un `() -> Void` non-Sendable. Un no-op frais est
    // renvoyé quand aucun panneau n'injecte de fermeture.
    static var defaultValue: () -> Void { {} }
}

extension EnvironmentValues {
    /// Ferme la sheet/le pane adaptatif courant. Injecté par `.adaptivePane`.
    var paneDismiss: () -> Void {
        get { self[PaneDismissKey.self] }
        set { self[PaneDismissKey.self] = newValue }
    }
}

// MARK: - Environnement : contexte d'hôte (profondeur de présentation)

/// Où se trouve la vue courante dans la hiérarchie de présentation.
/// Détermine si un `.adaptivePane` demandé ici est de niveau 1 (→ inspecteur
/// sur macOS) ou de niveau 2+ (→ reste une sheet).
enum PaneHostContext {
    /// À même la fenêtre (aucun modal au-dessus) — un pane ouvert ici est niveau 1.
    case root
    /// Déjà dans une sheet — les panes enfants restent des sheets.
    case modal
    /// Déjà dans l'inspecteur macOS — les panes enfants deviennent des sheets.
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

// MARK: - PaneBarButton (cross-plateforme)

/// Descripteur d'un bouton de barre de panneau. Utilisé par le chrome custom
/// macOS (`PaneScaffold`) MAIS AUSSI par `paneChrome` côté iOS (mappé sur des
/// `ToolbarItem`) — il doit donc vivre HORS du bloc `#if os(macOS)`. Struct pur,
/// aucune dépendance AppKit.
struct PaneBarButton: Identifiable, Equatable {
    let id = UUID()
    let label: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var disabled: Bool = false
    /// Affiche le titre à côté de l'icône (sinon icône seule si `systemImage`).
    var showsTitle: Bool = true
    let action: () -> Void

    /// Manuelle : `action` (closure) n'est pas `Equatable`. Comparaison sur
    /// l'état VISUEL — suffisant pour piloter `.onPreferenceChange` (détecter
    /// un changement de libellé/icône/`disabled` d'un rendu à l'autre).
    static func == (lhs: PaneBarButton, rhs: PaneBarButton) -> Bool {
        lhs.label == rhs.label && lhs.systemImage == rhs.systemImage
            && lhs.role == rhs.role && lhs.disabled == rhs.disabled && lhs.showsTitle == rhs.showsTitle
    }
}

// MARK: - Taille de la sheet macOS

private extension View {
    /// Borne la sheet sur macOS pour un rendu confortable (no-op sur iOS, où la
    /// sheet gère sa taille nativement). Ne concerne que la branche sheet — le
    /// contenu de l'inspecteur est dimensionné par `inspectorColumnWidth`.
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

/// Slot UNIQUE de présentation pour l'inspecteur global macOS.
/// Possédé par `MainTabView` (`@State`) et injecté dans l'environnement de tout
/// le layout — les `.adaptivePane` de niveau 1 y routent leur contenu au lieu
/// de présenter une sheet.
///
/// Sémantique « remplacement » : présenter un pane pendant qu'un autre est ouvert
/// remplace le contenu et appelle le `onDismiss` de l'ancien (reset du binding de
/// son call site). L'`onChange` de l'ancien modifier voit alors un id différent
/// dans le slot → no-op (pas de double fermeture).
/// Design B — « barre native en haut » : le contenu du panneau PUBLIE son chrome
/// (titre + boutons) ici, et `MainTabView` le rend comme de VRAIS `ToolbarItem`
/// natifs dans la barre système, séparés des outils du module par un
/// `ToolbarSpacer`. Aucune barre custom dessinée dans le panneau.
struct PaneChromeModel: Equatable {
    var title: String
    /// Bouton de gauche du groupe inspecteur (Fermer / Annuler).
    var leading: PaneBarButton?
    /// Boutons de droite (Supprimer, Modifier / Enregistrer…), ordre visuel.
    var trailing: [PaneBarButton]
}

@Observable @MainActor
final class InspectorPaneCenter {
    struct Pane: Identifiable {
        /// Identité de RENDU : régénérée à CHAQUE présentation (même call site),
        /// pour que `.id(pane.id)` recrée le sous-arbre → le `@State` du contenu
        /// (ex. `MacEntityPane.current`) est ré-amorcé avec la nouvelle donnée.
        /// Sans ça, cliquer une 2ᵉ transaction ne changeait pas le détail.
        let id: UUID
        /// Identité du PROPRIÉTAIRE (call site) : stable tant que le même
        /// `.adaptivePane` pilote le pane. Sert au dé-doublonnage des fermetures.
        let ownerId: UUID
        let content: AnyView
        /// Reset le binding du call site (isPresented = false / item = nil).
        let onDismiss: () -> Void
    }

    private(set) var pane: Pane?

    /// Présente (ou re-présente) le pane d'un call site donné.
    /// - Même `ownerId` (re-présentation, ex. autre ligne cliquée) : on remplace
    ///   le contenu avec un `id` de rendu FRAIS, sans fermer (pas de onDismiss).
    /// - `ownerId` différent (un autre écran ouvre un pane) : on ferme d'abord
    ///   l'ancien (reset de SON binding) puis on installe le nouveau.
    func present(ownerId: UUID, content: AnyView, onDismiss: @escaping () -> Void) {
        if let current = pane, current.ownerId != ownerId {
            current.onDismiss()
        }
        pane = Pane(id: UUID(), ownerId: ownerId, content: content, onDismiss: onDismiss)
    }

    /// Fermeture initiée par l'inspecteur lui-même (croix, toggle, changement de
    /// module) : vide le slot PUIS reset le binding du caller.
    func dismissCurrent() {
        guard let current = pane else { return }
        pane = nil
        current.onDismiss()
    }

    /// Fermeture initiée par le call site (binding passé à false/nil) : le
    /// binding est déjà reset, on vide juste le slot si c'est bien ce pane.
    func dismissIfCurrent(_ ownerId: UUID) {
        guard pane?.ownerId == ownerId else { return }
        pane = nil
    }
}

// MARK: - Métriques du panneau (macOS)

/// Largeurs du panneau, passées à `.inspectorColumnWidth(min:ideal:max:)`.
/// L'utilisateur redimensionne en tirant le séparateur ; macOS mémorise la
/// largeur choisie par fenêtre, on n'a donc rien à persister nous-mêmes.
///
/// `min` doit rester assez large pour que les `Form` du panneau (label + champ
/// sur une ligne) ne se cassent pas, `max` assez borné pour que la colonne du
/// module reste utilisable sur un écran de portable.
enum InspectorPaneMetrics {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 440
    static let maxWidth: CGFloat = 760
}

// MARK: - Chrome du panneau → barre système (macOS)

/// Déclare la `.toolbar` du contenu du panneau, DEPUIS ce contenu.
///
/// Sur macOS toute `.toolbar` de l'arbre remonte dans la barre unifiée de la
/// fenêtre : le panneau y pose donc ses actions comme n'importe quelle vue, et
/// elles cohabitent avec celles du module. Deux raisons de le faire ICI plutôt
/// que de faire transiter un modèle d'actions vers `MainTabView` :
///
/// 1. **Fraîcheur** — les closures sont celles du rendu COURANT du contenu.
///    Router le chrome via un objet observable relu dans un `.toolbar` distant
///    donnait des boutons figés sur leur premier rendu (Fermer/Supprimer sans
///    effet, `disabled` jamais réévalué) : SwiftUI ne réévalue pas de façon
///    fiable un contenu de toolbar sur simple changement observable.
/// 2. **Groupement et position** — les items du panneau sont un
///    `ToolbarItemGroup` (le groupement natif ; `ControlGroup` rendait tantôt
///    une pilule, tantôt des boutons isolés) précédé d'un **écart de la largeur
///    du panneau**. Résultat : les actions du panneau s'alignent sur le bord
///    droit du PANNEAU, celles du module sur le bord droit du MODULE — chaque
///    groupe est physiquement au-dessus de la colonne à laquelle il appartient,
///    l'appartenance se lit sans étiquette.
private struct InspectorChromeToolbar: ViewModifier {
    let make: () -> PaneChromeModel

    func body(content: Content) -> some View {
        let chrome = make()
        return content.toolbar {
            // `ToolbarSpacer` est l'API PRÉVUE pour séparer deux groupes de la
            // barre : elle pousse le groupe suivant vers le bord droit ET rompt le
            // fond de verre partagé, donc deux pilules distinctes. Un espaceur
            // « fait main » (`Color.clear` dans un ToolbarItem) ne marche pas : il
            // est traité comme un item ordinaire et se peint en pilule vide,
            // collée aux boutons.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
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

    /// Icône seule + tooltip QUAND une icône a été fournie ; **libellé texte
    /// sinon**.
    ///
    /// ⚠️ Ne JAMAIS inventer une icône par défaut pour une action qui n'en
    /// déclare pas. Une version antérieure repliait tout bouton de confirmation
    /// sur un ✓ : « Tout accepter » (qui crée en masse des récurrents détectés)
    /// est ainsi devenu un simple ✓, lu comme « OK/fermer » — un clic a créé 157
    /// récurrents d'un coup. Un libellé explicite est plus long mais ne peut pas
    /// être confondu.
    @ViewBuilder
    private func barButton(_ button: PaneBarButton) -> some View {
        Button(role: button.role, action: button.action) {
            if let icon = button.systemImage {
                Image(systemName: icon)
            } else {
                Text(button.label)
            }
        }
        .disabled(button.disabled)
        .help(button.label)
        .accessibilityLabel(button.label)
        .tint(button.role == .destructive ? AppTheme.Colors.danger : AppTheme.Colors.accent)
    }
}

extension View {
    /// Déclare le chrome (titre + actions) de ce contenu de panneau dans la barre
    /// système macOS. Cf. `InspectorChromeToolbar`.
    func publishesInspectorChrome(_ make: @escaping () -> PaneChromeModel) -> some View {
        modifier(InspectorChromeToolbar(make: make))
    }
}

// MARK: - Modifiers de routage (macOS)

/// Variante booléenne : route vers l'inspecteur global au niveau 1, sinon sheet.
private struct AdaptivePaneBoolModifier<PaneContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    /// Équivalent du `onDismiss:` de `.sheet` — appelé à la fermeture du pane,
    /// quel que soit le chemin (binding, remplacement, changement de module).
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
                        // Tous les chemins de fermeture repassent ici (le center
                        // reset le binding) → un seul point d'appel de onDismiss.
                        center.dismissIfCurrent(paneId)
                        onDismiss?()
                    }
                }
                .onAppear {
                    // Binding déjà true au montage (état restauré, présentation
                    // programmée avant l'apparition).
                    if isPresented { presentPane(center) }
                }
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                paneContent()
                    .environment(\.paneDismiss, { isPresented = false })
                    .environment(\.paneHostContext, .modal)
                    .adaptivePaneFrame()
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
            ),
            onDismiss: { isPresented = false }
        )
    }
}

/// Variante `Identifiable?` : route vers l'inspecteur global au niveau 1, sinon sheet.
private struct AdaptivePaneItemModifier<Item: Identifiable, PaneContent: View>: ViewModifier {
    @Binding var item: Item?
    /// Cf. AdaptivePaneBoolModifier.onDismiss.
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
                        // Présentation ou re-présentation (item remplacé à chaud).
                        presentPane(center, value: value)
                    } else {
                        center.dismissIfCurrent(paneId)
                        onDismiss?()
                    }
                }
                .onAppear {
                    if let value = item { presentPane(center, value: value) }
                }
        } else {
            content.sheet(item: $item, onDismiss: onDismiss) { value in
                paneContent(value)
                    .environment(\.paneDismiss, { item = nil })
                    .environment(\.paneHostContext, .modal)
                    .adaptivePaneFrame()
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
            ),
            onDismiss: { item = nil }
        )
    }
}

#endif

// MARK: - EntityDetailEditPane (cross-plateforme) : détail lecture seule ⇄ édition

/// Conteneur "entité" pour une donnée EXISTANTE, sur **iOS et macOS** : le tap
/// ouvre d'abord un **détail lecture seule** (Fermer / Supprimer / Modifier),
/// puis « Modifier » bascule sur le formulaire d'édition existant (Annuler /
/// Enregistrer). Les DEUX chemins de sortie du formulaire (Annuler comme
/// post-save) reviennent au détail : le `\.paneDismiss` injecté ré-fetch l'item
/// via `refresh` — après un save, le détail est donc à jour ; après un cancel,
/// no-op visuel.
///
/// `.paneChrome` sur le détail s'adapte déjà à la plateforme/au contexte
/// (barre système macOS niveau 1, `NavigationStack`+toolbar natif iOS/sheet) —
/// ce conteneur n'a donc RIEN de spécifique à macOS.
private struct EntityDetailEditPane<Item, DetailContent: View, EditContent: View>: View {
    let title: String
    /// Re-fetch frais depuis le repository (jamais depuis des arrays capturés).
    /// nil = l'item n'existe plus (supprimé ailleurs) → on garde le snapshot.
    let refresh: (Item) -> Item?
    /// Route vers le flux de suppression existant du parent (confirmationDialog
    /// de la liste, etc.). Le pane se ferme immédiatement après.
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
            // Le formulaire publie SON chrome (Annuler / Enregistrer) via
            // `.paneChrome`. Annuler ET dismiss post-save reviennent au détail.
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
                    confirmLabel: "Modifier", onConfirm: { isEditing = true }
                )
        }
    }

    private func endEditing() {
        current = refresh(current) ?? current
        isEditing = false
    }
}

// MARK: - paneChrome : chrome adaptatif formulaire/écran

/// Remplace le couple `NavigationStack { … }.toolbar { Annuler / Enregistrer }`
/// des formulaires et écrans présentés en pane/sheet :
/// - **iOS**, et **macOS niveau 2** (sheet, fenêtre séparée) : `NavigationStack`
///   + `.toolbar` natifs (comportement historique, rendu dans la sheet).
/// - **macOS niveau 1** (inspecteur) : le contenu est rendu NU et publie son
///   chrome (Annuler / Enregistrer) vers la barre système (Design B).
private struct PaneChromeModifier: ViewModifier {
    let title: String
    let cancel: PaneBarButton?
    /// Bouton destructif optionnel (ex. Supprimer), rendu AVANT `confirm` dans
    /// le groupe trailing — pour les écrans détail (Fermer / Supprimer / Modifier).
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
            navStack(content)
        }
        #else
        navStack(content)
        #endif
    }

    @ViewBuilder
    private func navStack(_ content: Content) -> some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar {
                    if let cancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(cancel.label, action: cancel.action)
                        }
                    }
                    if let destructive {
                        ToolbarItem(placement: .destructiveAction) {
                            Button(role: .destructive, action: destructive.action) {
                                Label(destructive.label, systemImage: destructive.systemImage ?? "trash")
                            }
                        }
                    }
                    if let confirm {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirm.label, action: confirm.action)
                                .disabled(confirm.disabled)
                        }
                    }
                }
        }
    }
}

extension View {
    /// Chrome adaptatif pour un formulaire/écran (cf. `PaneChromeModifier`).
    /// Appliquer sur le CONTENU (Form/ScrollView) SANS `NavigationStack` ni
    /// `.toolbar` propres — ce modifier les fournit selon la plateforme/contexte.
    /// `destructiveLabel`/`onDestructive` : bouton Supprimer optionnel (écrans
    /// détail Fermer / Supprimer / Modifier).
    func paneChrome(
        _ title: String,
        cancelLabel: String? = nil,
        onCancel: (() -> Void)? = nil,
        destructiveLabel: String? = nil,
        onDestructive: (() -> Void)? = nil,
        confirmLabel: String? = nil,
        confirmDisabled: Bool = false,
        onConfirm: (() -> Void)? = nil
    ) -> some View {
        modifier(PaneChromeModifier(
            title: title,
            cancel: (cancelLabel != nil && onCancel != nil)
                ? PaneBarButton(label: cancelLabel!, action: onCancel!)
                : nil,
            destructive: (destructiveLabel != nil && onDestructive != nil)
                ? PaneBarButton(label: destructiveLabel!, systemImage: "trash", role: .destructive, showsTitle: false, action: onDestructive!)
                : nil,
            confirm: (confirmLabel != nil && onConfirm != nil)
                ? PaneBarButton(label: confirmLabel!, disabled: confirmDisabled, action: onConfirm!)
                : nil
        ))
    }
}

// MARK: - paneChromeInline : variante pour contenu avec push interne

/// Variante de `.paneChrome` pour un contenu qui a BESOIN de garder sa PROPRE
/// `NavigationStack` (parce qu'il contient un `NavigationLink`/push interne —
/// un push depuis le panneau macOS sans `NavigationStack` locale n'a pas de
/// contexte de navigation fiable). Appliquer directement DANS cette
/// `NavigationStack`, au même niveau que `.navigationTitle`/`.toolbar` (PAS
/// à l'extérieur — un `.toolbar` posé hors d'une `NavigationStack` ne
/// s'accroche à rien et disparaît silencieusement).
///
/// - iOS, et macOS niveau 2 (sheet) : `.navigationTitle` + `.toolbar` natifs,
///   exactement comme le pattern historique — la `NavigationStack` locale les
///   affiche normalement.
/// - macOS niveau 1 (inspecteur) : AUCUN `.navigationTitle`/`.toolbar` posé ici
///   (la `NavigationStack` locale reste, nue, pour que le push interne
///   fonctionne) ; le chrome est publié séparément vers la barre système.
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
            nativeChrome(content)
        }
        #else
        nativeChrome(content)
        #endif
    }

    @ViewBuilder
    private func nativeChrome(_ content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancel.label, action: cancel.action)
                    }
                }
                if let confirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirm.label, action: confirm.action)
                            .disabled(confirm.disabled)
                    }
                }
            }
    }
}

extension View {
    /// Cf. `PaneChromeInlineModifier`. Appliquer DANS la `NavigationStack`
    /// existante (sur son contenu), jamais à l'extérieur.
    func paneChromeInline(
        _ title: String,
        cancelLabel: String? = nil,
        onCancel: (() -> Void)? = nil,
        confirmLabel: String? = nil,
        confirmDisabled: Bool = false,
        onConfirm: (() -> Void)? = nil
    ) -> some View {
        modifier(PaneChromeInlineModifier(
            title: title,
            cancel: (cancelLabel != nil && onCancel != nil)
                ? PaneBarButton(label: cancelLabel!, action: onCancel!)
                : nil,
            confirm: (confirmLabel != nil && onConfirm != nil)
                ? PaneBarButton(label: confirmLabel!, disabled: confirmDisabled, action: onConfirm!)
                : nil
        ))
    }
}

// MARK: - API publique

extension View {
    /// Tap « détail » macOS : ouvre le panneau détail au clic sur une row.
    /// No-op sur iOS, où les rows gardent leur comportement historique
    /// (swipe pour éditer/supprimer, pas de tap).
    @ViewBuilder
    func macDetailTap(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onTapGesture(perform: action)
        #else
        self
        #endif
    }

    /// Pane "entité" pour une donnée EXISTANTE, UNIFIÉ iOS + macOS : le tap
    /// ouvre un détail lecture seule (Fermer / Supprimer / Modifier) → « Modifier »
    /// bascule sur `edit` (Annuler / Enregistrer) → retour au détail rafraîchi
    /// via `refresh`. Sur macOS niveau 1, le détail vit dans le panneau latéral ;
    /// sur iOS (et macOS niveau 2), en sheet — même logique, présentation adaptée.
    /// - `onDelete` doit router vers le flux de suppression existant du parent.
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

    /// Présente `content` selon un booléen : inspecteur global sur macOS au
    /// niveau 1, sheet partout ailleurs.
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

    /// Variante pilotée par un `Identifiable?` (équivalent `.sheet(item:)`).
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
