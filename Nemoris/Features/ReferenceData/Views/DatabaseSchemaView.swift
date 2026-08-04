import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Doc navigable du schéma SQLite, accessible depuis la Console SQL.
/// Liste toutes les tables groupées par domaine avec leurs colonnes, relations,
/// et quelques exemples de requêtes prêts à copier.
///
/// ⚠️ Source statique : si tu ajoutes une migration qui change le schéma, mets à
/// jour `SchemaDoc.domains` ci-dessous (cf. version courante du schéma dans
/// `DatabaseManager.migrations` — v44 au moment de l'écriture).
///
/// Cette doc alimente AUSSI le prompt de l'assistant SQL (`SQLAssistantService.
/// systemInstructions` → `SchemaDoc.llmSchemaPrompt`) : une colonne listée ici
/// mais absente en base fait halluciner l'assistant sur une colonne inexistante.
struct DatabaseSchemaView: View {
    @State private var expandedTables: Set<String> = []
    @State private var copiedQuery: String? = nil

    var body: some View {
        List {
            Section {
                Text("Nemoris stocke toutes tes données dans une base SQLite locale (`finance.sqlite` dans Application Support). Voici les tables disponibles pour tes requêtes — tape sur une table pour voir ses colonnes et un exemple.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } header: { Text("Vue d'ensemble") }

            ForEach(SchemaDoc.domains, id: \.name) { domain in
                Section(domain.name) {
                    ForEach(domain.tables, id: \.name) { table in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedTables.contains(table.name) },
                                set: { isOn in
                                    if isOn { expandedTables.insert(table.name) }
                                    else { expandedTables.remove(table.name) }
                                }
                            ),
                            content: { tableContent(table) },
                            label:   { tableHeader(table) }
                        )
                    }
                }
            }

            Section("Recettes prêtes à copier") {
                ForEach(SchemaDoc.recipes, id: \.title) { recipe in
                    recipeRow(recipe)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚙️ Conventions").font(.caption.bold())
                    Text("• Dates au format ISO `YYYY-MM-DD HH:MM:SS` (UTC). Utilise `strftime('%Y-%m', tx_date)` pour grouper par mois.")
                    Text("• Montants en EUR (Double). Négatif = dépense, positif = revenu.")
                    Text("• IDs auto-incrémentés (INTEGER PRIMARY KEY).")
                    Text("• Foreign keys non strictement enforcées par SQLite — vérifie tes jointures.")
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .navigationTitle("Schéma de la base")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let copied = copiedQuery {
                HStack {
                    Image(systemName: "doc.on.clipboard.fill")
                    Text("Copié : \(copied.prefix(40))…").font(.caption.bold())
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(AppTheme.Colors.accent.opacity(0.3), lineWidth: 1))
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header / Content

    private func tableHeader(_ table: SchemaTable) -> some View {
        HStack(spacing: 10) {
            Image(systemName: table.systemImage)
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(table.name)
                    .font(.subheadline.monospaced().weight(.semibold))
                Text(table.summary)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func tableContent(_ table: SchemaTable) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Description
            Text(table.description)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(.top, 4)

            // Columns
            VStack(alignment: .leading, spacing: 4) {
                Text("Colonnes").font(.caption.bold()).foregroundStyle(AppTheme.Colors.textSecondary)
                ForEach(table.columns, id: \.name) { col in
                    columnRow(col)
                }
            }

            // Relations (FK)
            if !table.relations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Relations").font(.caption.bold()).foregroundStyle(AppTheme.Colors.textSecondary)
                    ForEach(table.relations, id: \.self) { rel in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                            Text(rel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
            }

            // Example
            if let example = table.example {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Exemple").font(.caption.bold()).foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                        Button {
                            copy(example.sql)
                        } label: {
                            Label("Copier", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(example.title)
                        .font(.caption.italic())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(example.sql)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func columnRow(_ col: SchemaColumn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Indicateur PK / FK
            ZStack {
                if col.isPrimaryKey {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.Colors.warning)
                } else if col.isForeignKey {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.Colors.accent)
                } else {
                    Circle().fill(Color.clear).frame(width: 10, height: 10)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(col.name)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(col.type)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if !col.nullable {
                        Text("NOT NULL").font(.system(size: 8).weight(.bold)).foregroundStyle(AppTheme.Colors.warning)
                    }
                }
                if !col.description.isEmpty {
                    Text(col.description)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func recipeRow(_ recipe: SchemaRecipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: recipe.icon)
                    .foregroundStyle(AppTheme.Colors.accent)
                Text(recipe.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    copy(recipe.sql)
                } label: {
                    Label("Copier", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            Text(recipe.sql)
                .font(.system(.caption2, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(6)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Copy

    private func copy(_ sql: String) {
        UIPasteboard.general.string = sql
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            copiedQuery = sql
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { copiedQuery = nil }
        }
    }
}

// MARK: - Schema model

struct SchemaColumn {
    let name: String
    let type: String
    let nullable: Bool
    let isPrimaryKey: Bool
    let isForeignKey: Bool
    let description: String

    init(_ name: String, _ type: String, nullable: Bool = true, pk: Bool = false, fk: Bool = false, _ description: String = "") {
        self.name = name; self.type = type; self.nullable = nullable
        self.isPrimaryKey = pk; self.isForeignKey = fk
        self.description = description
    }
}

struct SchemaExample {
    let title: String
    let sql: String
}

struct SchemaTable {
    let name: String
    let systemImage: String
    let summary: String
    let description: String
    let columns: [SchemaColumn]
    let relations: [String]
    let example: SchemaExample?
}

struct SchemaDomain {
    let name: String
    let tables: [SchemaTable]
}

struct SchemaRecipe {
    let title: String
    let icon: String
    let sql: String
}

// MARK: - Schema data (source of truth pour la doc — à mettre à jour avec les migrations)

enum SchemaDoc {

    static let domains: [SchemaDomain] = [
        coreDomain,
        importDomain,
        budgetDomain,
        tricountDomain,
        investmentsDomain,
        patrimoineDomain,
        goalsDomain
    ]

    /// Toutes les tables aplaties (sans regroupement par domaine).
    static var allTables: [SchemaTable] { domains.flatMap(\.tables) }

    /// Rendu **ultra-compact** du schéma pour le prompt LLM. Format DDL-like
    /// sans descriptions — seulement les noms de tables/colonnes, types et FK.
    /// Doit rester sous ~1500 tokens pour tenir dans la fenêtre de contexte
    /// limitée d'Apple Foundation Models (on-device, ~4k tokens max).
    ///
    /// La doc détaillée reste dans `domains` pour `DatabaseSchemaView`.
    static let llmSchemaPrompt: String = {
        var lines: [String] = []
        for domain in domains {
            lines.append("-- \(domain.name)")
            for table in domain.tables {
                var cols: [String] = []
                for col in table.columns {
                    var flags = col.type
                    if col.isPrimaryKey { flags += " PK" }
                    if col.isForeignKey { flags += " FK" }
                    if !col.nullable    { flags += " NN" }
                    cols.append("\(col.name) \(flags)")
                }
                lines.append("\(table.name)(\(cols.joined(separator: ", ")))")
                // Only include relations if they reference other tables
                let crossRefs = table.relations.filter { $0.contains("→") }
                if !crossRefs.isEmpty {
                    lines.append("  FK: \(crossRefs.joined(separator: " ; "))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }()

    // MARK: Core

    private static let coreDomain = SchemaDomain(
        name: "Core (transactions & référentiel)",
        tables: [
            SchemaTable(
                name: "accounts",
                systemImage: "creditcard",
                summary: "Comptes bancaires (courant, épargne, etc.)",
                description: "Chaque transaction est rattachée à un compte. Un compte de type EPARGNE est ignoré dans les graphiques principaux.",
                columns: [
                    .init("id",   "INTEGER", nullable: false, pk: true, "Identifiant auto"),
                    .init("name", "TEXT", "Nom affiché (ex. « Compte BNP courant »)"),
                    .init("type", "TEXT", nullable: false, "COURANT | EPARGNE | DIFFERE | AUTRE"),
                ],
                relations: ["transactions.account_id → accounts.id"],
                example: .init(
                    title: "Solde par compte",
                    sql: "SELECT a.name, SUM(t.amount) AS solde\nFROM accounts a\nLEFT JOIN transactions t ON t.account_id = a.id\nGROUP BY a.id\nORDER BY solde DESC;"
                )
            ),
            SchemaTable(
                name: "categories",
                systemImage: "square.grid.2x2",
                summary: "Catégories hiérarchiques (parent/enfant)",
                description: "Arbre à 2 niveaux : Alimentation > Supermarché. Une catégorie sans parent est une racine. `icon` est un nom SF Symbol.",
                columns: [
                    .init("id",        "INTEGER", nullable: false, pk: true),
                    .init("name",      "TEXT", "Ex. « Alimentation »"),
                    .init("parent_id", "INTEGER", fk: true, "NULL = catégorie racine"),
                    .init("icon",      "TEXT", "SF Symbol (ex. « cart.fill »). NULL = auto-déterminé depuis le nom"),
                ],
                relations: [
                    "categories.parent_id → categories.id (self)",
                    "transactions.category_id → categories.id",
                    "payees.category_id → categories.id"
                ],
                example: .init(
                    title: "Total par catégorie sur le mois",
                    sql: "SELECT c.name, SUM(t.amount) AS total\nFROM transactions t\nJOIN categories c ON c.id = t.category_id\nWHERE strftime('%Y-%m', t.tx_date) = strftime('%Y-%m', 'now')\nGROUP BY c.id\nORDER BY total ASC;"
                )
            ),
            SchemaTable(
                name: "payees",
                systemImage: "person.crop.circle",
                summary: "Tiers / commerçants (anciennement « tiers »)",
                description: "Tous les marchands, contacts P2P et tiers personnalisés. `engine_merchant_id` lie au moteur canonique. `domain` sert au favicon (AXE A).",
                columns: [
                    .init("id",                 "INTEGER", nullable: false, pk: true),
                    .init("name",               "TEXT", "Nom affiché (ex. « Carrefour Market — Oullins »)"),
                    .init("regex",              "TEXT", "Regex legacy d'auto-matching"),
                    .init("category_id",        "INTEGER", fk: true, "Catégorie par défaut des nouvelles transactions"),
                    .init("linked_account_id",  "INTEGER", fk: true, "Pour les virements internes (pointe vers le compte cible)"),
                    .init("city",               "TEXT", "AXE C — ville pour matching moteur"),
                    .init("country",            "TEXT", "ISO 3166-1 alpha-2 (ex. « FR »)"),
                    .init("address",            "TEXT"),
                    .init("engine_merchant_id", "TEXT", "ID canonique côté NemorisEngine (ex. « carrefour »)"),
                    .init("group_id",           "INTEGER", fk: true, "Groupe de marque (toutes les enseignes Carrefour)"),
                    .init("custom",             "INTEGER", nullable: false, "1 = créé par user, pas réassigné auto par moteur"),
                    .init("domain",             "TEXT", "AXE A — pour favicon Google (v20)"),
                    .init("note",               "TEXT", "AXE C — note libre du user (v21)"),
                    .init("tier_type",          "TEXT", nullable: false, "AXE F (v25) — 'merchant' | 'contact' | 'internal' | 'organization'"),
                    .init("contact_identifier", "TEXT", "AXE F (v25) — CNContact.identifier si tier_type='contact'"),
                ],
                relations: [
                    "payees.group_id → payee_groups.id",
                    "transactions.payee_id → payees.id"
                ],
                example: .init(
                    title: "Top 10 marchands par dépense",
                    sql: "SELECT p.name, SUM(t.amount) AS depense, COUNT(*) AS nb\nFROM transactions t\nJOIN payees p ON p.id = t.payee_id\nWHERE t.amount < 0\nGROUP BY p.id\nORDER BY depense ASC\nLIMIT 10;"
                )
            ),
            SchemaTable(
                name: "payee_groups",
                systemImage: "building.2",
                summary: "Groupes de marque (chaînes d'enseignes)",
                description: "Regroupe plusieurs `payees` partageant la même marque. Ex. plusieurs payees « Carrefour Market — Lyon », « Carrefour City — Paris » → tous dans le groupe « Carrefour ».",
                columns: [
                    .init("id",                  "INTEGER", nullable: false, pk: true),
                    .init("display_name",        "TEXT", nullable: false),
                    .init("engine_merchant_id",  "TEXT", "Pour matching auto avec le moteur"),
                    .init("custom",              "INTEGER", nullable: false, "1 = créé par user"),
                    .init("created_at",          "INTEGER", "Unix timestamp"),
                ],
                relations: ["payees.group_id → payee_groups.id"],
                example: nil
            ),
            SchemaTable(
                name: "transactions",
                systemImage: "list.bullet.rectangle",
                summary: "Toutes les transactions financières",
                description: "Une ligne = une opération bancaire. `libelle_brut` = le libellé original du CSV/banque ; `information` = note libre éditable par le user.",
                columns: [
                    .init("id",                       "INTEGER", nullable: false, pk: true),
                    .init("account_id",               "INTEGER", fk: true, "Compte d'origine"),
                    .init("payee_id",                 "INTEGER", fk: true, "Tiers (peut être NULL pour opé bancaire interne)"),
                    .init("category_id",              "INTEGER", fk: true, "NULL = non catégorisé"),
                    .init("payment_type_id",          "INTEGER", fk: true, "CB, Virement, Prélèvement…"),
                    .init("information",              "TEXT", "Note libre user"),
                    .init("libelle_brut",             "TEXT", "Libellé bancaire original (depuis v9)"),
                    .init("amount",                   "REAL", "Négatif = dépense, positif = revenu"),
                    .init("tx_date",                  "TEXT", "Date au format ISO"),
                ],
                relations: [
                    "→ accounts.id",
                    "→ payees.id (payee_id)",
                    "→ categories.id",
                    "→ payment_types.id",
                    "← reimbursements.transaction_id (0..1, si remboursée par un tiers — v44)"
                ],
                example: .init(
                    title: "Dépenses par mois sur l'année",
                    sql: "SELECT strftime('%Y-%m', tx_date) AS mois,\n       SUM(CASE WHEN amount < 0 THEN amount ELSE 0 END) AS depenses,\n       SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END) AS revenus\nFROM transactions\nWHERE strftime('%Y', tx_date) = strftime('%Y', 'now')\nGROUP BY mois\nORDER BY mois;"
                )
            ),
            SchemaTable(
                name: "reimbursements",
                systemImage: "arrow.uturn.left.circle",
                summary: "Suivi des remboursements attendus d'un tiers",
                description: "Rattachée à une transaction simple OU une entrée Tricount (jamais les deux — v44). Côté transaction : 0..1 payee, `amount` NULL (= montant entier de la transaction). Côté Tricount : 0..N payees, `amount` = part personnelle éditable.",
                columns: [
                    .init("id",                "INTEGER", nullable: false, pk: true),
                    .init("transaction_id",    "INTEGER", fk: true, "XOR avec tricount_entry_id"),
                    .init("tricount_entry_id", "INTEGER", fk: true, "XOR avec transaction_id"),
                    .init("payee_id",          "INTEGER", nullable: false, fk: true, "Le tiers qui doit rembourser"),
                    .init("amount",            "REAL", "NULL si transaction_id (montant implicite = celui de la transaction)"),
                    .init("currency",          "TEXT", nullable: false),
                    .init("status",            "TEXT", nullable: false, "PENDING | RECEIVED"),
                ],
                relations: ["→ transactions.id", "→ tricount_entries.id", "→ payees.id"],
                example: .init(
                    title: "Total attendu par tiers (en attente)",
                    sql: "SELECT p.name, SUM(r.amount) AS total\nFROM reimbursements r\nJOIN payees p ON p.id = r.payee_id\nWHERE r.status = 'PENDING'\nGROUP BY p.id\nORDER BY total DESC;"
                )
            ),
            SchemaTable(
                name: "payment_types",
                systemImage: "creditcard.circle",
                summary: "Moyens de paiement (CB, Virement, etc.)",
                description: "Référentiel court : CB, Virement, Prélèvement, Espèces, Chèque, AUTRE.",
                columns: [
                    .init("id",    "INTEGER", nullable: false, pk: true),
                    .init("name",  "TEXT"),
                    .init("regex", "TEXT", "Regex legacy"),
                ],
                relations: ["transactions.payment_type_id → payment_types.id"],
                example: nil
            ),
            SchemaTable(
                name: "tags",
                systemImage: "tag",
                summary: "Tags libres pour transactions et Tricount",
                description: "Tags transversaux applicables aux transactions et aux entrées Tricount via deux tables de jointure.",
                columns: [
                    .init("id",    "INTEGER", nullable: false, pk: true),
                    .init("name",  "TEXT", nullable: false, "UNIQUE COLLATE NOCASE"),
                    .init("color", "TEXT", "Hex sans # (ex. « 8B5CF6 »). NULL = couleur par défaut"),
                ],
                relations: ["transaction_tags(tag_id) ↔ transactions",
                            "tricount_entry_tags(tag_id) ↔ tricount_entries"],
                example: .init(
                    title: "Dépenses par tag sur 90 jours",
                    sql: "SELECT g.name AS tag, SUM(t.amount) AS total\nFROM transactions t\nJOIN transaction_tags tt ON tt.transaction_id = t.id\nJOIN tags g ON g.id = tt.tag_id\nWHERE t.tx_date >= date('now', '-90 days')\nGROUP BY g.id\nORDER BY total ASC;"
                )
            ),
            SchemaTable(
                name: "transaction_tags",
                systemImage: "link",
                summary: "Jointure many-to-many transactions ↔ tags",
                description: "Une ligne = un tag posé sur une transaction. ON DELETE CASCADE des deux côtés.",
                columns: [
                    .init("transaction_id", "INTEGER", nullable: false, fk: true),
                    .init("tag_id",         "INTEGER", nullable: false, fk: true),
                ],
                relations: ["→ transactions.id", "→ tags.id"],
                example: nil
            ),
            SchemaTable(
                name: "tricount_entry_tags",
                systemImage: "link",
                summary: "Jointure many-to-many tricount_entries ↔ tags",
                description: "Une ligne = un tag posé sur une dépense Tricount. ON DELETE CASCADE des deux côtés.",
                columns: [
                    .init("entry_id", "INTEGER", nullable: false, fk: true),
                    .init("tag_id",   "INTEGER", nullable: false, fk: true),
                ],
                relations: ["→ tricount_entries.id", "→ tags.id"],
                example: nil
            ),
        ]
    )

    // MARK: Import (AXE D + E + B)

    private static let importDomain = SchemaDomain(
        name: "Import",
        tables: [
            SchemaTable(
                name: "import_sessions",
                systemImage: "tray.and.arrow.down",
                summary: "Sessions d'import CSV en cours / terminées",
                description: "Stocke l'état complet de la session sous forme de JSON (`rows_json`). Une seule session `active` à la fois. Status : active | completed | cancelled.",
                columns: [
                    .init("id",          "TEXT", nullable: false, pk: true, "UUID"),
                    .init("created_at",  "TEXT", nullable: false),
                    .init("updated_at",  "TEXT", nullable: false),
                    .init("status",      "TEXT", nullable: false),
                    .init("source_file", "TEXT", "Nom du fichier CSV importé"),
                    .init("account_id",  "INTEGER", fk: true),
                    .init("total_rows",  "INTEGER", nullable: false),
                    .init("rows_json",   "TEXT", nullable: false, "JSON [ImportSessionRow]"),
                ],
                relations: ["import_sessions.account_id → accounts.id"],
                example: .init(
                    title: "Historique des imports",
                    sql: "SELECT id, status, source_file, total_rows,\n       datetime(created_at) AS depuis\nFROM import_sessions\nORDER BY created_at DESC;"
                )
            ),
            SchemaTable(
                name: "csv_mappings",
                systemImage: "tablecells",
                summary: "Mappings colonnes CSV mémorisés par format",
                description: "Indexé par `header_signature` (concat des noms de colonnes en lowercased+sans accents). Un même format CSV de banque n'est mappé qu'une fois.",
                columns: [
                    .init("id",                  "INTEGER", nullable: false, pk: true),
                    .init("header_signature",    "TEXT", nullable: false, "UNIQUE"),
                    .init("date_column_index",   "INTEGER", nullable: false),
                    .init("amount_column_index", "INTEGER", nullable: false),
                    .init("label_column_index",  "INTEGER", nullable: false),
                    .init("separator",           "TEXT", "« ; », « , » ou « \\t »"),
                    .init("date_format",         "TEXT", "Ex. « dd/MM/yyyy »"),
                    .init("amount_decimal",      "TEXT", "« , » ou « . »"),
                    .init("created_at",          "TEXT", nullable: false),
                ],
                relations: [],
                example: nil
            ),
            // enrichment_cache : DROPPED en v36. Le cache d'enrichissement (Sirene,
            // MapKit, LLM) est maintenant dans `Library/Caches/nemoris/enrichment_cache.json`
            // via `JSONFileCache`. Pas dans la DB user — ce sont des données récupérables
            // via APIs externes.
        ]
    )

    // MARK: Budget

    private static let budgetDomain = SchemaDomain(
        name: "Budget & Prévisions",
        tables: [
            SchemaTable(
                name: "recurring_patterns",
                systemImage: "arrow.clockwise.circle",
                summary: "Dépenses/revenus récurrents (détectés ou manuels)",
                description: "Frequency : MONTHLY | WEEKLY | YEARLY. `is_manual` = 1 si saisi par l'utilisateur (vs détecté).",
                columns: [
                    .init("id",               "INTEGER", nullable: false, pk: true),
                    .init("name",             "TEXT", nullable: false),
                    .init("amount_avg",       "REAL", nullable: false),
                    .init("amount_tolerance", "REAL", nullable: false, "± fraction acceptable (0.15 = 15 %)"),
                    .init("category_id",      "INTEGER", fk: true),
                    .init("payee_id",         "INTEGER", fk: true),
                    .init("frequency",        "TEXT", nullable: false),
                    .init("anchor_day",       "INTEGER", "Jour du mois (1-31)"),
                    .init("is_active",        "INTEGER", nullable: false),
                    .init("is_manual",        "INTEGER", nullable: false),
                    .init("created_at",       "TEXT", nullable: false),
                    .init("last_detected_at", "TEXT"),
                    .init("start_date",       "TEXT", nullable: false, "À partir de quand prévoir"),
                    .init("end_date",         "TEXT", "NULL = sans fin"),
                ],
                relations: ["→ categories.id", "→ payees.id"],
                example: nil
            ),
            SchemaTable(
                name: "budget_envelopes",
                systemImage: "envelope",
                summary: "Enveloppes budgétaires par catégorie",
                description: "Period : MONTHLY (par défaut). `amount` = plafond sur la période.",
                columns: [
                    .init("id",          "INTEGER", nullable: false, pk: true),
                    .init("name",        "TEXT", nullable: false),
                    .init("category_id", "INTEGER", fk: true),
                    .init("amount",      "REAL", nullable: false),
                    .init("period",      "TEXT", nullable: false),
                    .init("start_date",  "TEXT", nullable: false),
                    .init("is_active",   "INTEGER", nullable: false),
                ],
                relations: ["→ categories.id"],
                example: nil
            ),
            SchemaTable(
                name: "budget_previsions",
                systemImage: "calendar.badge.clock",
                summary: "Échéances prévisionnelles (générées depuis recurring_patterns)",
                description: "Status : PENDING (à venir) | MATCHED (transaction réelle trouvée) | SKIPPED.",
                columns: [
                    .init("id",                     "INTEGER", nullable: false, pk: true),
                    .init("recurring_pattern_id",   "INTEGER", fk: true),
                    .init("amount",                 "REAL", nullable: false),
                    .init("expected_date",          "TEXT", nullable: false),
                    .init("status",                 "TEXT", nullable: false),
                    .init("actual_transaction_id",  "INTEGER", fk: true, "Si MATCHED"),
                    .init("notes",                  "TEXT"),
                ],
                relations: ["→ recurring_patterns.id", "→ transactions.id"],
                example: .init(
                    title: "Prévisions du mois en cours",
                    sql: "SELECT bp.expected_date, rp.name, bp.amount, bp.status\nFROM budget_previsions bp\nJOIN recurring_patterns rp ON rp.id = bp.recurring_pattern_id\nWHERE strftime('%Y-%m', bp.expected_date) = strftime('%Y-%m', 'now')\nORDER BY bp.expected_date;"
                )
            ),
        ]
    )

    // MARK: Tricount

    private static let tricountDomain = SchemaDomain(
        name: "Tricount (dépenses partagées)",
        tables: [
            SchemaTable(
                name: "tricount_groups",
                systemImage: "person.2",
                summary: "Groupes Tricount synchronisés",
                description: "Un groupe = un Tricount (chacun avec son `tricount_key` côté API).",
                columns: [
                    .init("id",           "INTEGER", nullable: false, pk: true),
                    .init("tricount_key", "TEXT", nullable: false),
                    .init("title",        "TEXT", nullable: false),
                    .init("currency",     "TEXT", "EUR par défaut"),
                    .init("my_name",      "TEXT", nullable: false, "Comment l'utilisateur s'appelle dans ce groupe"),
                    .init("fetched_at",   "TEXT", nullable: false),
                ],
                relations: ["tricount_entries.group_id → tricount_groups.id"],
                example: nil
            ),
            SchemaTable(
                name: "tricount_entries",
                systemImage: "list.dash",
                summary: "Entrées d'un Tricount",
                description: "Type : NORMAL | REIMBURSEMENT. `linked_transaction_id` lie l'entrée à une vraie transaction bancaire si l'user l'a rapprochée.",
                columns: [
                    .init("id",                    "INTEGER", nullable: false, pk: true),
                    .init("group_id",              "INTEGER", nullable: false, fk: true),
                    .init("source_entry_uuid",     "TEXT", "ID côté API Tricount"),
                    .init("source_updated_at",     "TEXT"),
                    .init("type_transaction",      "TEXT", nullable: false),
                    .init("who_paid",              "TEXT", nullable: false),
                    .init("total",                 "REAL", nullable: false),
                    .init("currency",              "TEXT", nullable: false),
                    .init("local_total",           "REAL", "En monnaie locale si conversion"),
                    .init("local_currency",        "TEXT"),
                    .init("description",           "TEXT"),
                    .init("date",                  "TEXT", nullable: false),
                    .init("category",              "TEXT"),
                    .init("user_category_id",      "INTEGER", fk: true, "Catégorie Nemoris customisée"),
                    .init("linked_transaction_id", "INTEGER", fk: true),
                ],
                relations: ["→ tricount_groups.id", "→ transactions.id", "→ categories.id"],
                example: nil
            ),
            SchemaTable(
                name: "tricount_shares",
                systemImage: "divide",
                summary: "Répartition d'une entrée entre membres",
                description: "Combien chaque participant doit pour une entrée donnée.",
                columns: [
                    .init("id",          "INTEGER", nullable: false, pk: true),
                    .init("entry_id",    "INTEGER", nullable: false, fk: true),
                    .init("member_name", "TEXT", nullable: false),
                    .init("amount",      "REAL", nullable: false),
                ],
                relations: ["→ tricount_entries.id"],
                example: nil
            ),
        ]
    )

    // MARK: Investments

    private static let investmentsDomain = SchemaDomain(
        name: "Investissements",
        tables: [
            SchemaTable(
                name: "investment_accounts",
                systemImage: "chart.line.uptrend.xyaxis",
                summary: "Comptes d'investissement (CTO, PEA, etc.)",
                description: "Account_type : CTO | PEA | ASSURANCE_VIE | CRYPTO_EXCHANGE | CRYPTO_WALLET. Séparé de la table accounts. Pas de colonne `current_value`/`invested_amount` stockée (DROP COLUMN en v30) — valorisation totale = SUM(investment_positions.current_value) + cash_balance, voir l'exemple ci-dessous.",
                columns: [
                    .init("id",              "INTEGER", nullable: false, pk: true),
                    .init("name",            "TEXT", nullable: false),
                    .init("broker",          "TEXT", nullable: false),
                    .init("currency",        "TEXT", nullable: false, "EUR par défaut"),
                    .init("account_type",    "TEXT", nullable: false),
                    .init("opened_at",       "TEXT", nullable: false),
                    .init("cash_balance",    "REAL", nullable: false, "Trésorerie disponible (v34)"),
                ],
                relations: ["investment_positions.account_id → investment_accounts.id"],
                example: .init(
                    title: "Valorisation totale des comptes",
                    sql: "SELECT a.name, a.broker, a.account_type,\n       COALESCE(SUM(p.current_value), 0) + a.cash_balance AS total\nFROM investment_accounts a\nLEFT JOIN investment_positions p ON p.account_id = a.id\nGROUP BY a.id\nORDER BY total DESC;"
                )
            ),
            SchemaTable(
                name: "investment_positions",
                systemImage: "chart.bar",
                summary: "Positions individuelles (actions, ETF, etc.)",
                description: "Asset_type : STOCK | ETF | BOND | CRYPTO. Pas de colonne `quantity`/`average_buy_price`/`purchase_date` stockée (DROP COLUMN en v30) — calculées à la volée depuis `investment_orders` (voir l'exemple : même logique que `InvestmentRepository.fetchAccounts()`). `current_value` reste une colonne stockée (qty × dernier cours connu, mise à jour par la sync). Cours historiques en cache disque (Library/Caches), plus en SQL.",
                columns: [
                    .init("id",                  "INTEGER", nullable: false, pk: true),
                    .init("account_id",          "INTEGER", nullable: false, fk: true),
                    .init("asset_type",          "TEXT", nullable: false),
                    .init("asset_name",          "TEXT", nullable: false),
                    .init("ticker",              "TEXT", "Ex. « HO.PA », « AAPL », « BTC »"),
                    .init("isin",                "TEXT", "Identifiant universel ISIN (v31, ex. « FR0000121329 »)"),
                    .init("current_value",       "REAL", nullable: false, "qty × dernier cours connu"),
                ],
                relations: ["→ investment_accounts.id", "investment_orders.position_id → investment_positions.id"],
                example: .init(
                    title: "Performance par position (qty/PRU dérivés des ordres)",
                    sql: "WITH position_summary AS (\n    SELECT p.id, p.asset_name, p.ticker, p.current_value,\n           COALESCE(SUM(CASE WHEN o.order_type='BUY'  THEN o.quantity ELSE 0 END), 0)\n             - COALESCE(SUM(CASE WHEN o.order_type='SELL' THEN o.quantity ELSE 0 END), 0) AS qty,\n           COALESCE(SUM(CASE WHEN o.order_type='BUY' THEN o.quantity*o.unit_price + o.fees ELSE 0 END), 0)\n             / NULLIF(SUM(CASE WHEN o.order_type='BUY' THEN o.quantity ELSE 0 END), 0) AS pru\n    FROM investment_positions p\n    LEFT JOIN investment_orders o ON o.position_id = p.id\n    GROUP BY p.id\n)\nSELECT asset_name, ticker, qty, pru, current_value,\n       (current_value - qty * pru) AS gain_perte\nFROM position_summary\nWHERE qty > 0\nORDER BY gain_perte DESC;"
                )
            ),
            SchemaTable(
                name: "investment_orders",
                systemImage: "list.bullet.indent",
                summary: "Ordres BUY / SELL / DIV par position (AXE K, v28)",
                description: "Une ligne par opération chronologique. La position parent est recalculée (qty + PRU + purchase_date) à chaque add/update/delete via `recomputePositionFromOrders`. `external_id` (v33) est l'ID natif côté provider (ex. « binance_BTCUSDT_3848291 ») — UNIQUE quand non-NULL pour dédup atomique des trades LiveSync.",
                columns: [
                    .init("id",          "INTEGER", nullable: false, pk: true),
                    .init("position_id", "INTEGER", nullable: false, fk: true),
                    .init("order_type",  "TEXT", nullable: false, "BUY | SELL | DIV"),
                    .init("quantity",    "REAL", nullable: false, "Toujours positive, signe porté par order_type"),
                    .init("unit_price",  "REAL", nullable: false, "Prix unitaire à l'exécution"),
                    .init("fees",        "REAL", nullable: false, "0 par défaut"),
                    .init("executed_at", "TEXT", nullable: false, "yyyy-MM-dd"),
                    .init("notes",       "TEXT"),
                    .init("external_id", "TEXT", "ID natif provider (ex. binance_BTCUSDT_3848291)"),
                ],
                relations: ["→ investment_positions.id (ON DELETE CASCADE)"],
                example: .init(
                    title: "Historique des achats d'une position",
                    sql: "SELECT o.executed_at, o.order_type, o.quantity, o.unit_price, o.fees\nFROM investment_orders o\nJOIN investment_positions p ON p.id = o.position_id\nWHERE p.ticker = 'BTC'\nORDER BY o.executed_at DESC;"
                )
            ),
            SchemaTable(
                name: "investment_live_sync",
                systemImage: "arrow.triangle.2.circlepath",
                summary: "Liens de synchronisation auto (Binance, EVM, BTC, SOL) — AXE I",
                description: "Un lien = un compte chez un provider externe. Les credentials sont stockés dans le Keychain (jamais en clair en DB). `config_json` contient des paramètres optionnels (ex. chain pour EVM).",
                columns: [
                    .init("id",                        "INTEGER", nullable: false, pk: true),
                    .init("provider_id",               "TEXT", nullable: false, "binance | evm_wallet | bitcoin_wallet | solana_wallet"),
                    .init("display_name",              "TEXT", nullable: false),
                    .init("account_id",                "INTEGER", fk: true, "investment_accounts.id (ON DELETE CASCADE)"),
                    .init("config_json",               "TEXT", "JSON params (ex. {\"chain\":\"polygon\"})"),
                    .init("enabled",                   "INTEGER", nullable: false),
                    .init("last_sync_at",              "TEXT"),
                    .init("last_sync_status",          "TEXT", "ok | error | pending"),
                    .init("last_sync_message",         "TEXT"),
                    .init("show_tokens_without_price", "INTEGER", nullable: false),
                    .init("created_at",                "TEXT", nullable: false),
                ],
                relations: ["→ investment_accounts.id"],
                example: nil
            ),
            SchemaTable(
                name: "currency_rates",
                systemImage: "dollarsign.arrow.circlepath",
                summary: "Taux de change historiques (Tricount multi-devise)",
                description: "Cache local. UNIQUE(from_currency, to_currency, date) ON CONFLICT REPLACE. Utilisé par les JOINs des repos Transaction et Tricount pour convertir les montants étrangers en EUR.",
                columns: [
                    .init("id",             "INTEGER", nullable: false, pk: true),
                    .init("from_currency",  "TEXT", nullable: false),
                    .init("to_currency",    "TEXT", nullable: false, "EUR par défaut"),
                    .init("date",           "TEXT", nullable: false),
                    .init("rate",           "REAL", nullable: false),
                ],
                relations: [],
                example: nil
            ),
        ]
    )

    // MARK: Patrimoine (v37-v38)

    private static let patrimoineDomain = SchemaDomain(
        name: "Patrimoine (Net Worth)",
        tables: [
            SchemaTable(
                name: "patrimoine_real_estate",
                systemImage: "house",
                summary: "Biens immobiliers (saisie manuelle)",
                description: "Plus-value estimée = `current_value - purchase_price`. L'estimation peut être mise à jour manuellement (`estimated_at` = date de la dernière estimation).",
                columns: [
                    .init("id",             "INTEGER", nullable: false, pk: true),
                    .init("name",           "TEXT", nullable: false, "Ex. « Appartement Lyon 3 »"),
                    .init("purchase_price", "REAL", nullable: false, "Prix d'achat"),
                    .init("purchase_date",  "TEXT", nullable: false),
                    .init("current_value",  "REAL", nullable: false, "Valeur estimée actuelle"),
                    .init("estimated_at",   "TEXT", "Date de la dernière estimation"),
                    .init("address",        "TEXT"),
                    .init("notes",          "TEXT"),
                    .init("created_at",     "TEXT", nullable: false),
                ],
                relations: ["patrimoine_loans.linked_real_estate_id → patrimoine_real_estate.id"],
                example: .init(
                    title: "Plus-value par bien",
                    sql: "SELECT name, purchase_price, current_value,\n       ROUND(current_value - purchase_price, 2) AS plus_value,\n       ROUND((current_value - purchase_price) * 100.0 / purchase_price, 1) AS pct\nFROM patrimoine_real_estate\nORDER BY plus_value DESC;"
                )
            ),
            SchemaTable(
                name: "patrimoine_loans",
                systemImage: "banknote",
                summary: "Prêts & dettes (immobilier, conso, etc.)",
                description: "loan_type : AMORT | IN_FINE | DEFERRED_TOTAL | DEFERRED_PARTIAL | REVOLVING. Le capital restant dû est calculé en mémoire (LoanCalculator.swift). `insurance_monthly` (v38) = charge mensuelle séparée de la mensualité du prêt.",
                columns: [
                    .init("id",                     "INTEGER", nullable: false, pk: true),
                    .init("name",                   "TEXT", nullable: false),
                    .init("loan_type",              "TEXT", nullable: false, "AMORT | IN_FINE | DEFERRED_TOTAL | DEFERRED_PARTIAL | REVOLVING"),
                    .init("principal",              "REAL", nullable: false, "Montant emprunté"),
                    .init("annual_rate",            "REAL", nullable: false, "Taux annuel (ex. 0.025 = 2.5%)"),
                    .init("duration_months",        "INTEGER", nullable: false),
                    .init("deferral_months",        "INTEGER", nullable: false, "0 si pas de différé"),
                    .init("start_date",             "TEXT", nullable: false),
                    .init("linked_real_estate_id",  "INTEGER", fk: true, "ON DELETE SET NULL"),
                    .init("insurance_monthly",      "REAL", nullable: false, "Assurance emprunteur mensuelle (v38)"),
                    .init("notes",                  "TEXT"),
                    .init("created_at",             "TEXT", nullable: false),
                ],
                relations: ["→ patrimoine_real_estate.id (soft FK)"],
                example: .init(
                    title: "Coût mensuel total des prêts",
                    sql: "SELECT name, loan_type, principal, annual_rate,\n       duration_months, insurance_monthly\nFROM patrimoine_loans\nORDER BY principal DESC;"
                )
            ),
            SchemaTable(
                name: "patrimoine_assets",
                systemImage: "dollarsign.circle",
                summary: "Éléments mobiliers & liquidités (cash, livrets, PEA…)",
                description: "Chaque asset est soit standalone (`manual_value`), soit lié à un `accounts.id` ou `investment_accounts.id` (exactement 1 link max, UNIQUE INDEX partiels). Linking soft (ON DELETE SET NULL). `last_known_value` = dernière valeur calculée depuis le compte lié.",
                columns: [
                    .init("id",                            "INTEGER", nullable: false, pk: true),
                    .init("name",                          "TEXT", nullable: false),
                    .init("asset_kind",                    "TEXT", nullable: false, "CASH | LIVRET | PEA | CTO | CRYPTO | AUTRE"),
                    .init("linked_account_id",             "INTEGER", fk: true, "→ accounts.id (ON DELETE SET NULL)"),
                    .init("linked_investment_account_id",   "INTEGER", fk: true, "→ investment_accounts.id (ON DELETE SET NULL)"),
                    .init("manual_value",                  "REAL", nullable: false, "Valeur manuelle si standalone"),
                    .init("last_known_value",              "REAL", nullable: false, "Dernière valeur calculée depuis le lien"),
                    .init("notes",                         "TEXT"),
                    .init("created_at",                    "TEXT", nullable: false),
                ],
                relations: ["→ accounts.id (soft)", "→ investment_accounts.id (soft)"],
                example: .init(
                    title: "Patrimoine total mobilier",
                    sql: "SELECT name, asset_kind,\n       CASE WHEN linked_account_id IS NOT NULL OR linked_investment_account_id IS NOT NULL\n            THEN last_known_value\n            ELSE manual_value\n       END AS valeur\nFROM patrimoine_assets\nORDER BY valeur DESC;"
                )
            ),
        ]
    )

    // MARK: Goals (v39)

    private static let goalsDomain = SchemaDomain(
        name: "Objectifs financiers",
        tables: [
            SchemaTable(
                name: "goals",
                systemImage: "target",
                summary: "Objectifs financiers (épargne, patrimoine, etc.)",
                description: "kind : SAVINGS | NETWORTH | DEBT_PAYOFF | CUSTOM. Le progrès est calculé en mémoire (GoalsViewModel) en croisant avec le PatrimoineSnapshot. `custom_current_amount` n'est utilisé que pour kind=CUSTOM.",
                columns: [
                    .init("id",                    "INTEGER", nullable: false, pk: true),
                    .init("name",                  "TEXT", nullable: false),
                    .init("kind",                  "TEXT", nullable: false, "SAVINGS | NETWORTH | DEBT_PAYOFF | CUSTOM"),
                    .init("target_amount",         "REAL", nullable: false, "Montant cible"),
                    .init("deadline_date",         "TEXT", "Date limite (optionnelle)"),
                    .init("custom_current_amount", "REAL", nullable: false, "Montant actuel pour kind=CUSTOM"),
                    .init("notes",                 "TEXT"),
                    .init("created_at",            "TEXT", nullable: false),
                ],
                relations: [],
                example: .init(
                    title: "État des objectifs",
                    sql: "SELECT name, kind, target_amount, deadline_date,\n       custom_current_amount\nFROM goals\nORDER BY deadline_date NULLS LAST;"
                )
            ),
        ]
    )

    // MARK: Recipes

    static let recipes: [SchemaRecipe] = [
        SchemaRecipe(
            title: "Top 10 dépenses du mois",
            icon: "chart.bar.fill",
            sql: "SELECT t.tx_date, p.name AS tier, c.name AS categorie, t.amount\nFROM transactions t\nLEFT JOIN payees p ON p.id = t.payee_id\nLEFT JOIN categories c ON c.id = t.category_id\nWHERE t.amount < 0\n  AND strftime('%Y-%m', t.tx_date) = strftime('%Y-%m', 'now')\nORDER BY t.amount ASC\nLIMIT 10;"
        ),
        SchemaRecipe(
            title: "Solde réel par compte",
            icon: "creditcard.fill",
            sql: "SELECT a.name, a.type, COALESCE(SUM(t.amount), 0) AS solde\nFROM accounts a\nLEFT JOIN transactions t ON t.account_id = a.id\nGROUP BY a.id\nORDER BY a.type, a.name;"
        ),
        SchemaRecipe(
            title: "Évolution dépenses/revenus (12 mois)",
            icon: "chart.line.uptrend.xyaxis",
            sql: "SELECT strftime('%Y-%m', tx_date) AS mois,\n       ROUND(SUM(CASE WHEN amount < 0 THEN amount END), 2) AS depenses,\n       ROUND(SUM(CASE WHEN amount > 0 THEN amount END), 2) AS revenus,\n       ROUND(SUM(amount), 2) AS net\nFROM transactions\nWHERE tx_date >= date('now', '-12 months')\nGROUP BY mois\nORDER BY mois;"
        ),
        SchemaRecipe(
            title: "Transactions non catégorisées",
            icon: "questionmark.circle.fill",
            sql: "SELECT t.tx_date, p.name, t.libelle_brut, t.amount\nFROM transactions t\nLEFT JOIN payees p ON p.id = t.payee_id\nWHERE t.category_id IS NULL\nORDER BY t.tx_date DESC\nLIMIT 50;"
        ),
        SchemaRecipe(
            title: "Marchands sans catégorie par défaut",
            icon: "person.crop.circle.badge.exclamationmark",
            sql: "SELECT p.id, p.name, COUNT(t.id) AS nb_transactions\nFROM payees p\nLEFT JOIN transactions t ON t.payee_id = p.id\nWHERE p.category_id IS NULL\nGROUP BY p.id\nHAVING nb_transactions > 0\nORDER BY nb_transactions DESC;"
        ),
        SchemaRecipe(
            title: "Doublons potentiels (même montant, même jour)",
            icon: "doc.on.doc.fill",
            sql: "SELECT t1.id, t1.tx_date, t1.amount, t1.libelle_brut, t2.id AS dup_id\nFROM transactions t1\nJOIN transactions t2\n  ON t2.id > t1.id\n AND t2.amount = t1.amount\n AND date(t2.tx_date) = date(t1.tx_date)\n AND t2.account_id = t1.account_id\nORDER BY t1.tx_date DESC;"
        ),
        SchemaRecipe(
            title: "Dépenses moyennes par jour de semaine",
            icon: "calendar",
            sql: "SELECT CASE strftime('%w', tx_date)\n         WHEN '0' THEN '7-Dim' WHEN '1' THEN '1-Lun' WHEN '2' THEN '2-Mar'\n         WHEN '3' THEN '3-Mer' WHEN '4' THEN '4-Jeu' WHEN '5' THEN '5-Ven'\n         WHEN '6' THEN '6-Sam'\n       END AS jour,\n       ROUND(AVG(amount), 2) AS moyenne,\n       COUNT(*) AS nb\nFROM transactions\nWHERE amount < 0 AND tx_date >= date('now', '-1 year')\nGROUP BY jour\nORDER BY jour;"
        ),
        SchemaRecipe(
            title: "Patrimoine net (actifs − dettes)",
            icon: "building.columns.fill",
            sql: "SELECT 'Immobilier' AS type, SUM(current_value) AS valeur FROM patrimoine_real_estate\nUNION ALL\nSELECT 'Mobilier & Liquidités', SUM(COALESCE(last_known_value, manual_value)) FROM patrimoine_assets\nUNION ALL\nSELECT 'Investissements', SUM(p.current_value)\nFROM investment_positions p\nWHERE (\n    SELECT COALESCE(SUM(CASE WHEN o.order_type='BUY'  THEN o.quantity ELSE 0 END), 0)\n         - COALESCE(SUM(CASE WHEN o.order_type='SELL' THEN o.quantity ELSE 0 END), 0)\n    FROM investment_orders o WHERE o.position_id = p.id\n) > 0\nUNION ALL\nSELECT 'Dettes (prêts)', -SUM(principal) FROM patrimoine_loans;"
        ),
    ]
}
