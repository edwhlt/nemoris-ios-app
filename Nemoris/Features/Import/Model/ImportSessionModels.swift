import Foundation

// MARK: - ImportSession (AXE D + E)

/// Statut d'une session d'import. Une seule session 'active' à la fois en DB.
enum ImportSessionStatus: String, Codable {
    case active, completed, cancelled
}

/// Action utilisateur sur une ligne d'import.
enum ImportUserAction: String, Codable {
    case pending        // pas encore décidé
    case confirmed      // accepte la suggestion engine
    case manuallySet    // payee assigné manuellement
    case skipped        // ne sera pas importé
    case committed      // déjà insérée en base
}

/// Snapshot Codable d'une résolution moteur, pour persister dans rows_json.
/// On ne stocke pas directement `TierResolution` (enum à associated types non Codable).
enum TierResolutionSnapshot: Codable, Hashable {
    case pending                                          // engine pas encore appelé
    case matched(payeeId: Int?, engineMerchantId: String?,
                 displayName: String, city: String?, score: Double)
    case suggestCreate(engineMerchantId: String, displayName: String,
                       city: String?, country: String?, score: Double)
    case suggestContact(name: String, hint: String?)
    case systemOperation(category: String, displayName: String)
    case needsManualPick(reason: String, topMerchantId: String?,
                         topName: String?, topScore: Double?)
}

/// Une ligne d'un import en cours. Tout est Codable pour la persistance JSON.
struct ImportSessionRow: Identifiable, Codable, Hashable {
    let id: UUID
    /// Numéro de ligne dans le CSV source (1-indexed, sans le header).
    let sourceRowNumber: Int
    let rawLabel: String
    let date: Date
    let amount: Double
    let paymentTypeHint: String?

    var resolution: TierResolutionSnapshot
    var assignedPayeeId: Int?
    var assignedPayeeName: String?
    var assignedCategoryId: Int?
    var assignedPaymentTypeId: Int?
    var userAction: ImportUserAction
    /// Identifiant de cluster (pour grouper les libellés similaires). Optionnel.
    var clusterId: String?
    /// Id d'un tier CRÉÉ par cette ligne pendant la session (via « Créer un nouveau tier »).
    /// Permet de proposer sa suppression si la session est annulée (nettoyage des tiers fantômes).
    /// nil = aucun tier créé par cette ligne (lien vers un tier existant, ou pas encore décidé).
    var createdPayeeId: Int? = nil
    /// Fichier d'origine, quand une session agrège PLUSIEURS fichiers.
    /// `nil` pour une session mono-fichier (l'info est alors dans
    /// `ImportSession.sourceFile`).
    ///
    /// Propriété optionnelle avec valeur par défaut : le `Codable` synthétisé la
    /// décode en `decodeIfPresent`, donc les `rows_json` déjà persistés (sessions
    /// actives d'une version précédente) se relisent sans migration.
    var sourceFile: String? = nil

    init(id: UUID = UUID(),
         sourceRowNumber: Int,
         rawLabel: String,
         date: Date,
         amount: Double,
         paymentTypeHint: String? = nil,
         sourceFile: String? = nil)
    {
        self.id = id
        self.sourceRowNumber = sourceRowNumber
        self.rawLabel = rawLabel
        self.date = date
        self.amount = amount
        self.paymentTypeHint = paymentTypeHint
        self.sourceFile = sourceFile
        self.resolution = .pending
        self.userAction = .pending
    }
}

/// Représentation lourde d'une session : tout son contenu. Pour l'édition.
///
/// ⚠️ Le contenu dépend de la DESTINATION (colonne `destination`, migration v45) :
///   • `.transactions` → `rows`, qui portent l'état de résolution de chaque
///     ligne (tier assigné, action utilisateur) ;
///   • `.investments`  → `batch`, la sortie brute du pipeline.
///
/// Les deux ne fusionnent pas : une ligne de transaction traîne des décisions
/// utilisateur qu'un `ImportElement` n'a pas vocation à porter — c'est la
/// frontière entre l'ingestion (refondue) et la résolution (inchangée).
struct ImportSession: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: ImportSessionStatus
    var sourceFile: String?
    var accountId: Int?
    var destination: ImportDestination
    var rows: [ImportSessionRow]
    /// Sortie du pipeline, pour une session d'investissements.
    var batch: ImportBatchResult?

    init(id: UUID, createdAt: Date, updatedAt: Date, status: ImportSessionStatus,
         sourceFile: String?, accountId: Int?,
         destination: ImportDestination = .transactions,
         rows: [ImportSessionRow] = [], batch: ImportBatchResult? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.sourceFile = sourceFile
        self.accountId = accountId
        self.destination = destination
        self.rows = rows
        self.batch = batch
    }

    var totalRows: Int {
        destination == .transactions ? rows.count : (batch?.elements.count ?? 0)
    }
    var pendingRows: Int { rows.filter { $0.userAction == .pending }.count }
    var readyRows: Int { rows.filter { [.confirmed, .manuallySet].contains($0.userAction) }.count }
    var skippedRows: Int { rows.filter { $0.userAction == .skipped }.count }
}

/// Représentation légère utilisée pour le bandeau / l'index global.
/// Évite de charger tout le JSON quand on a juste besoin d'afficher "N lignes restantes".
struct ImportSessionSummary: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let status: ImportSessionStatus
    let sourceFile: String?
    let accountId: Int?
    let totalRows: Int
    let pendingRows: Int
    /// Où va cette session — c'est ce qui décide quel écran de revue rouvrir.
    var destination: ImportDestination = .transactions
}

// MARK: - ColumnMapping

/// Mapping des colonnes d'un CSV. Indexé par signature (concat des headers).
struct ColumnMapping: Codable, Hashable {
    let headerSignature: String
    var dateColumnIndex: Int
    var amountColumnIndex: Int
    var labelColumnIndex: Int
    var separator: String        // ";", ",", "\t"
    var dateFormat: String?      // "dd/MM/yyyy", "yyyy-MM-dd", etc. (nil = autodétection)
    var amountDecimal: String    // "," ou "."
}

/// Signature stable d'un header CSV : tous les noms en minuscules sans accents, joints par "|".
enum ColumnMappingSignature {
    static func compute(headers: [String]) -> String {
        headers
            .map { $0
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "|")
    }
}
