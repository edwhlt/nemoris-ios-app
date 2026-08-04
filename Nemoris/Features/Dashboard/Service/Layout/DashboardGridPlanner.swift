import Foundation

// MARK: - DashboardGridPlanner
//
// Répartit les cartes en lignes. **Fonction pure**, donc testable sans UI.
//
// **Pourquoi pas un `LazyVGrid`** : il ne sait pas faire de span — `gridCellColumns()`
// n'existe que sur `Grid`, qui n'est pas lazy (tout le contenu serait monté d'un
// coup). Et `GridItem(.adaptive(minimum:))` ne permet pas d'imposer qu'une carte
// occupe toute la largeur. On planifie donc les lignes nous-mêmes et on les rend
// dans un `LazyVStack` de `HStack`.

enum DashboardGridPlanner {

    /// Découpe les cartes en lignes en respectant l'ordre de l'utilisateur.
    ///
    /// - Une carte `.wide` occupe sa propre ligne, seule.
    /// - Les cartes `.compact` s'accumulent jusqu'à `columns`, et la ligne en cours
    ///   est fermée dès qu'on rencontre une `.wide` ou que la ligne est pleine.
    ///
    /// L'ordre est **toujours** préservé : on ne comble pas un trou avec une carte
    /// située plus bas, sinon réordonner dans l'écran de personnalisation donnerait
    /// un résultat imprévisible.
    static func rows(
        _ cards: [DashboardCardPreference],
        columns: Int
    ) -> [[DashboardCardPreference]] {
        let columns = max(1, columns)
        var rows: [[DashboardCardPreference]] = []
        var current: [DashboardCardPreference] = []

        func flush() {
            if !current.isEmpty {
                rows.append(current)
                current = []
            }
        }

        for card in cards {
            // Une carte compacte sur une grille à 1 colonne occupe la largeur pleine :
            // inutile de la distinguer d'une large.
            if card.size == .wide || columns == 1 {
                flush()
                rows.append([card])
                continue
            }
            current.append(card)
            if current.count == columns { flush() }
        }
        flush()
        return rows
    }
}

// MARK: - DashboardLayoutMetrics

enum DashboardLayoutMetrics {

    /// Nombre de colonnes selon la largeur disponible.
    ///
    /// ⚠️ Mesurée par un `GeometryReader` classique et non par `onGeometryChange` :
    /// ce dernier demande macOS 15+, or la cible du projet est macOS 14.0.
    static func columnCount(for width: CGFloat) -> Int {
        if width >= 900 { return 4 }   // Mac (fenêtre par défaut 1100×760), iPad paysage
        if width >= 500 { return 3 }   // iPad portrait, Mac étroit
        return 2                       // iPhone
    }

    /// Hauteur plancher d'une tuile. Les cartes d'une même ligne s'égalisent ensuite
    /// sur la plus haute (`maxHeight: .infinity` dans la tuile + alignement `.top`).
    static func minHeight(for size: DashboardCardSize) -> CGFloat {
        switch size {
        case .compact: return 132
        case .wide:    return 180
        }
    }
}
