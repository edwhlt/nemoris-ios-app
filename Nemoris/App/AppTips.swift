import TipKit

// MARK: - Dashboard

struct DashboardChartTip: Tip {
    var title: Text { Text("Graphique mensuel") }
    var message: Text? {
        Text("Ce graphique présente les recettes (vert) et dépenses (rouge) mois par mois sur l'année. Appuyez sur une barre pour sélectionner le mois et filtrer les catégories en dessous.")
    }
    var image: Image? { Image(systemName: "chart.bar") }
}

struct FilteredChartTip: Tip {
    var title: Text { Text("Graphique interactif") }
    var message: Text? {
        Text("Glissez votre doigt sur le graphique pour parcourir les périodes. Le tooltip affiche les recettes, dépenses et le solde cumulatif à ce moment. Changez la granularité (Jour / Semaine / Mois) selon la durée analysée.")
    }
    var image: Image? { Image(systemName: "hand.draw") }
}

// MARK: - Transactions

struct TransactionFilterTip: Tip {
    var title: Text { Text("Filtre sur toute la période") }
    var message: Text? {
        Text("Le filtre texte, catégorie et tag s'applique sur l'ensemble des transactions de la période — pas seulement celles visibles. Appuyez sur « Appliquer » pour lancer la recherche.")
    }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }
}

struct MultiSelectTip: Tip {
    var title: Text { Text("Sélection multiple") }
    var message: Text? {
        Text("Activez la sélection via le menu ··· → Sélectionner. Vous pouvez ensuite assigner des tags, un remboursement ou supprimer plusieurs transactions en une seule action.")
    }
    var image: Image? { Image(systemName: "checkmark.circle") }
}

struct TagsTip: Tip {
    var title: Text { Text("Tags transversaux") }
    var message: Text? {
        Text("Les tags permettent de regrouper transactions et dépenses Tricount indépendamment du compte ou de la catégorie. Idéal pour suivre un voyage, un projet ou un événement. La vue « Dépenses par tag » affiche le total consolidé.")
    }
    var image: Image? { Image(systemName: "tag") }
}

// MARK: - Tricount

struct TricountLinkTip: Tip {
    var title: Text { Text("Lier à une transaction bancaire") }
    var message: Text? {
        Text("Ce bouton permet de lier une dépense Tricount à un virement bancaire correspondant. Cela évite les doublons dans votre suivi et permet de retrouver le paiement réel depuis la liste des transactions.")
    }
    var image: Image? { Image(systemName: "link") }
}

struct TricountReimbursementTip: Tip {
    var title: Text { Text("Remboursements Tricount") }
    var message: Text? {
        Text("Assignez à chaque dépense la personne qui vous la rembourse (ou à qui vous la devez). L'onglet Remboursements regroupe toutes ces créances par tiers avec le total consolidé en EUR.")
    }
    var image: Image? { Image(systemName: "arrow.uturn.left.circle") }
}

// MARK: - Données de référence

struct TiersRegexTip: Tip {
    var title: Text { Text("Regex de détection") }
    var message: Text? {
        Text("Le champ Regex permet la reconnaissance automatique lors des imports CSV. Exemple : « LIDL » détecte toute transaction contenant ce mot (casse ignorée). Vous pouvez utiliser des expressions régulières complètes.")
    }
    var image: Image? { Image(systemName: "textformat.abc") }
}

struct CategoryHierarchyTip: Tip {
    var title: Text { Text("Catégories hiérarchiques") }
    var message: Text? {
        Text("Une catégorie peut avoir une catégorie parente, ce qui permet de regrouper vos dépenses par thème. Ex : « Alimentation » contient « Restaurant » et « Courses ».")
    }
    var image: Image? { Image(systemName: "folder") }
}

// MARK: - Budget

struct BudgetEnvelopeTip: Tip {
    var title: Text { Text("Enveloppes budgétaires") }
    var message: Text? {
        Text("Chaque enveloppe représente un budget mensuel alloué à une catégorie — et à toutes ses sous-catégories. La barre de progression indique votre consommation en temps réel. Appuyez sur une enveloppe pour voir les transactions associées.")
    }
    var image: Image? { Image(systemName: "envelope.open") }
}

// MARK: - Investissements

struct InvestmentsOverviewTip: Tip {
    var title: Text { Text("Suivi de portefeuille") }
    var message: Text? {
        Text("La valorisation est calculée en temps réel à partir du cours actuel de chaque position. La performance affiche le gain ou la perte par rapport au prix d'achat moyen. Importez vos positions via CSV ou saisissez-les manuellement.")
    }
    var image: Image? { Image(systemName: "chart.line.uptrend.xyaxis") }
}

// MARK: - Tricount balance

struct TricountBalanceTip: Tip {
    var title: Text { Text("Lecture du bandeau de solde") }
    var message: Text? {
        Text("« Mes dépenses » = ce que vous avez payé pour le groupe. « Ma part nette » = ce que vous devez réellement (votre quote-part). La différence donne « Je dois » ou « On me doit » selon qui a avancé quoi.")
    }
    var image: Image? { Image(systemName: "scalemass") }
}

// MARK: - Console SQL

struct SQLConsoleTip: Tip {
    var title: Text { Text("Console SQL — Utilisateurs avancés") }
    var message: Text? {
        Text("Cet outil exécute des requêtes SQL directement sur votre base de données. Une requête UPDATE ou DELETE mal formée peut modifier des données de façon irréversible. Exportez une sauvegarde (Paramètres) avant toute modification.")
    }
    var image: Image? { Image(systemName: "exclamationmark.triangle") }
    var actions: [Action] {
        [Action(id: "understood", title: "Compris")]
    }
}
