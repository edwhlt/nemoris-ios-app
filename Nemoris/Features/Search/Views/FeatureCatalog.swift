import SwiftUI

// MARK: - FeatureCatalog
//
// A catalog of the app's FEATURES/screens (not the data they
// contain — that's `SearchService`). Serves "where is X" search:
// "budget" must surface the Budget module even if the user has
// no envelope named "budget" yet.
//
// ⚠️ A SINGLE source, shared by `MoreView` (iOS, the "More" tab) and
// `SearchView` (global search, both platforms). Before this file,
// `MainTabView.MoreView` carried its own private copy — exactly the same
// bug class already paid for elsewhere in this repo (4 diverging
// envelope calculations): two implementations of the same list end up diverging.
//
// ⚠️ `.settings` is a SPECIAL case: there's no generic cross-platform
// hook to "open Settings from anywhere" (unlike
// `.tab` via `AppState.navigateToTab` and `.importCSV` via
// `AppState.openImportTool`) — on iPhone, Settings lives ONLY in `MoreView`'s
// local navigation stack (a classic `NavigationLink`). `MoreView`
// can therefore show it (it has the context to push it itself);
// `SearchView`, presented as a sheet/pane from ANY screen, doesn't
// have that stack — it filters out `.settings` entries rather than exposing
// a button whose tap would do nothing.

enum FeatureTarget {
    case tab(MainTabItem)
    case importCSV
    case settings
}

struct FeatureEntry: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let color: Color
    let keywords: [String]
    let target: FeatureTarget
}

enum FeatureCatalog {

    /// The full list, filtered by the modules the user has actually
    /// enabled (`AppState.showX`) — no point suggesting "Budget" in
    /// search if the user disabled that module.
    static func entries(for appState: AppState) -> [FeatureEntry] {
        var entries: [FeatureEntry] = [
            FeatureEntry(
                title: "Dashboard",
                description: "Vue annuelle de vos revenus, dépenses et répartition par catégorie.",
                icon: MainTabItem.dashboard.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["graphique", "bilan", "statistiques", "recettes", "dépenses", "année", "catégorie", "résumé"],
                target: .tab(.dashboard)
            ),
            FeatureEntry(
                title: "Transactions",
                description: "Historique complet de vos opérations bancaires. Filtrez par catégorie, tiers ou montant.",
                icon: MainTabItem.transactions.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["liste", "historique", "opérations", "banque", "filtrer", "recherche", "tiers", "solde", "chercher"],
                target: .tab(.transactions)
            ),
            FeatureEntry(
                title: "Importation",
                description: "Importez un relevé de compte bancaire ou un document pour alimenter l'application.",
                icon: "square.and.arrow.down",
                color: AppTheme.Colors.success,
                keywords: ["importer", "relevé", "banque", "fichier", "csv", "charger", "données", "démarrage", "ajouter", "pdf"],
                target: .importCSV
            ),
            FeatureEntry(
                title: "Données de référence",
                description: "Gérez vos tiers, catégories et métadonnées utilisés lors de l'import.",
                icon: MainTabItem.referenceData.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["tiers", "catégorie", "métadonnée", "regex", "fournisseur", "référentiel", "compte", "règle"],
                target: .tab(.referenceData)
            ),
            FeatureEntry(
                title: "Paramètres",
                description: "Configurez l'application : thème, langue, sauvegarde et base de données.",
                icon: "gearshape",
                color: AppTheme.Colors.textSecondary,
                keywords: ["réglages", "configuration", "thème", "langue", "sauvegarde", "exporter", "base de données", "couleur"],
                target: .settings
            ),
        ]
        if appState.showInvestments {
            entries.append(FeatureEntry(
                title: "Investissements",
                description: "Consulter vos investissements, planifier vos investissements et suivre vos rendements.",
                icon: MainTabItem.investments.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["investir", "investissement", "actifs", "valeur", "taux de rendement", "retour", "gain"],
                target: .tab(.investments)
            ))
        }
        if appState.showPatrimoine {
            entries.append(FeatureEntry(
                title: "Patrimoine",
                description: "Consulter et gérer votre patrimoine, en incluant actifs financiers et personnels.",
                icon: MainTabItem.patrimoine.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["actifs", "valeur", "taux de rendement", "retour", "gain"],
                target: .tab(.patrimoine)
            ))
        }
        if appState.showBudget {
            entries.append(FeatureEntry(
                title: "Budget",
                description: "Définissez des enveloppes budgétaires par catégorie et suivez vos dépenses en temps réel.",
                icon: MainTabItem.budget.systemImage,
                color: AppTheme.Colors.warning,
                keywords: ["enveloppe", "limite", "prévision", "plafond", "mensuel", "contrôle", "objectif"],
                target: .tab(.budget)
            ))
        }
        if appState.showTricount {
            entries.append(FeatureEntry(
                title: "Tricount",
                description: "Gérez les dépenses partagées en groupe et calculez qui doit rembourser qui.",
                icon: MainTabItem.tricount.systemImage,
                color: AppTheme.Colors.accent,
                keywords: ["partage", "groupe", "remboursement", "partager", "dépenses communes", "équité"],
                target: .tab(.tricount)
            ))
        }
        if appState.showSQLConsole {
            entries.append(FeatureEntry(
                title: "Console SQL",
                description: "Exécutez des requêtes SQL directes sur votre base de données. Assistant IA disponible.",
                icon: MainTabItem.sqlConsole.systemImage,
                color: AppTheme.Colors.textSecondary,
                keywords: ["sql", "requête", "base", "données", "schéma", "query", "console", "avancé"],
                target: .tab(.sqlConsole)
            ))
        }
        return entries
    }

    /// A keyword filter — every word of the query must appear
    /// somewhere in the title + description + keywords (AND, not OR: a
    /// 2-word query must not surface everything matching just one of them).
    static func matching(_ query: String, in appState: AppState) -> [FeatureEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let words = q.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return entries(for: appState).filter { entry in
            let corpus = ([entry.title, entry.description] + entry.keywords).joined(separator: " ").lowercased()
            return words.allSatisfy { corpus.contains($0) }
        }
    }
}
