import Foundation

/// Une table de valeurs brutes : en-têtes + lignes de cellules.
///
/// Moteur PUR. C'est le format de sortie COMMUN des sources tabulaires — CSV,
/// TSV et classeur XLSX — précisément parce qu'elles posent toutes la même
/// question à l'utilisateur : « quelle colonne est la date, laquelle le
/// montant, laquelle le libellé ? ».
///
/// ⚠️ Faire converger XLSX ici plutôt que lui écrire son propre écran de
/// mapping est ce qui évite de recréer la situation qu'on est en train de
/// démonter : l'app avait DÉJÀ trois imports CSV indépendants (transactions,
/// investissements, et le mapping mémorisé), avec trois détections de
/// séparateur et trois conventions décimales.
struct ImportGrid: Equatable, Codable, Hashable, Sendable {
    /// Noms de colonnes. Synthétiques (« Colonne 1 ») quand la source n'a pas
    /// de ligne d'en-tête reconnaissable.
    var headers: [String]
    /// Vrai quand la première ligne a été reconnue comme un en-tête et n'est
    /// donc PAS une donnée.
    var hasExplicitHeader: Bool
    /// Les lignes de données, sans l'en-tête.
    var rows: [[String]]
    /// Séparateur retenu pour une source texte. Chaîne vide pour un classeur,
    /// dont les cellules sont déjà délimitées par le format.
    var separator: String
    /// Nom de la feuille, pour un classeur multi-feuilles.
    var sheetName: String?

    init(headers: [String], hasExplicitHeader: Bool, rows: [[String]],
         separator: String = "", sheetName: String? = nil) {
        self.headers = headers
        self.hasExplicitHeader = hasExplicitHeader
        self.rows = rows
        self.separator = separator
        self.sheetName = sheetName
    }

    /// Vrai quand la table a assez de structure pour qu'un mapping de colonnes
    /// ait un sens.
    ///
    /// ⚠️ Une source à UNE seule colonne n'est pas un tableau : c'est un relevé
    /// en prose. L'envoyer à l'écran de mapping demanderait à l'utilisateur de
    /// désigner des colonnes qui n'existent pas — elle part au parseur de
    /// documents à la place.
    var isTabular: Bool { !rows.isEmpty && headers.count >= 2 }
}
