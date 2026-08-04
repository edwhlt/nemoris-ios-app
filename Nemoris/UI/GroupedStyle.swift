import SwiftUI

// MARK: - Style standard des conteneurs groupés (AXE N.1)
//
// macOS n'a pas d'équivalent natif du `.insetGrouped` iOS pour `List` — d'où
// des écrans "bruts" (rows bord-à-bord, sections plates) sur desktop alors que
// l'app est en cartes arrondies sur iOS. Deux outils pour homogénéiser :
//
// 1. `nemorisFormStyle()` — pour tout `Form` : boxes arrondies natives macOS
//    (`.formStyle(.grouped)`, look System Settings) peintes dans la palette
//    via les `.listRowBackground` existants. No-op sur iOS (Form y est déjà
//    rendu insetGrouped).
// 2. `macGroupedRow(first:last:background:)` — pour les `List` dynamiques qui
//    ne peuvent pas devenir des Form (rowActions, pagination, refreshable…) :
//    dessine la carte par row via `.listRowBackground` (coins arrondis sur la
//    première/dernière row du groupe, séparateur interne façon insetGrouped).
//    La List doit être en `.listStyle(.plain)` sur macOS (base neutre).
//
// ⚠️ Conventions :
// - Tout nouveau `Form` doit recevoir `.nemorisFormStyle()`.
// - Ne jamais combiner `ZStack { Color.ignoresSafeArea(); Form }` (hauteur
//   infinie sur macOS, cf. CLAUDE.md AXE N.1) — `Form { … }.background(…)`.

extension View {
    /// Style standard des `Form` : grouped natif macOS (boxes arrondies) +
    /// remplissage du volet détail (sans quoi le Form macOS prend sa largeur
    /// intrinsèque étroite). No-op sur iOS.
    func nemorisFormStyle() -> some View {
        #if os(macOS)
        return self
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        return self
        #endif
    }

    /// Carte arrondie par row pour les `List` qui restent des `List`.
    /// Sur iOS : applique simplement `.listRowBackground(background)` (le
    /// `.insetGrouped` natif dessine les cartes). Sur macOS : coins arrondis
    /// first/last + inset horizontal + séparateur interne + respiration entre
    /// groupes.
    ///
    /// ⚠️ Implémentation macOS : la carte est le fond DU CONTENU (`.background`
    /// sur la row), PAS un `.listRowBackground`. Le placement du row background
    /// vis-à-vis des `listRowInsets` n'est pas fiable sur macOS (padding bas
    /// asymétrique constaté) — en attachant le fond au contenu, la géométrie
    /// est déterministe : la carte enveloppe exactement contenu + paddings.
    func macGroupedRow<Bg: View>(
        first: Bool = true,
        last: Bool = true,
        @ViewBuilder background: () -> Bg
    ) -> some View {
        #if os(macOS)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            // Padding interne de la carte (symétrique haut/bas par construction).
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.top, first ? AppTheme.Spacing.sm : AppTheme.Spacing.xs)
            .padding(.bottom, last ? AppTheme.Spacing.sm : AppTheme.Spacing.xs)
            .background(
                background()
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: first ? AppTheme.Radius.lg : 0,
                        bottomLeadingRadius: last ? AppTheme.Radius.lg : 0,
                        bottomTrailingRadius: last ? AppTheme.Radius.lg : 0,
                        topTrailingRadius: first ? AppTheme.Radius.lg : 0
                    ))
            )
            .overlay(alignment: .bottom) {
                if !last {
                    Divider()
                        .padding(.horizontal, AppTheme.Spacing.lg)
                }
            }
            // Marges HORS carte via PADDING RÉEL (toujours appliqué), et NON via
            // `listRowInsets` dont l'honoration est incertaine sur macOS `.plain`
            // — c'est ce qui laissait les cartes "collées aux bords" malgré la
            // valeur d'inset. Inset latéral + respiration après le dernier row.
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.bottom, last ? AppTheme.Spacing.md : 0)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        #else
        return self.listRowBackground(background())
        #endif
    }

    /// Variante avec fond `surface` standard.
    func macGroupedRow(first: Bool = true, last: Bool = true) -> some View {
        macGroupedRow(first: first, last: last) { AppTheme.Colors.surface }
    }

    /// Aligne un header de section sur le bord gauche des cartes
    /// `macGroupedRow`. No-op sur iOS.
    func macGroupedSectionHeader() -> some View {
        #if os(macOS)
        // Aligné sur le bord gauche des cartes (même marge latérale que le
        // padding hors-carte de `macGroupedRow`).
        return self.padding(.leading, AppTheme.Spacing.xl)
        #else
        return self
        #endif
    }
}
