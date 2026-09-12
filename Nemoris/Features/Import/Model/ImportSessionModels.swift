import Foundation

// MARK: - ImportSession

/// Status of an import session. Only one 'active' session at a time in the DB.
enum ImportSessionStatus: String, Codable {
    case active, completed, cancelled
}

/// User action on an import row.
enum ImportUserAction: String, Codable {
    case pending        // not yet decided
    case confirmed      // accepts the engine suggestion
    case manuallySet    // payee assigned manually
    case skipped        // won't be imported
    case committed      // already inserted into the database
}

/// Codable snapshot of an engine resolution, for persisting into rows_json.
/// We don't store `TierResolution` directly (an enum with associated types isn't Codable).
enum TierResolutionSnapshot: Codable, Hashable {
    case pending                                          // engine not called yet
    case matched(payeeId: Int?, engineMerchantId: String?,
                 displayName: String, city: String?, score: Double)
    case suggestCreate(engineMerchantId: String, displayName: String,
                       city: String?, country: String?, score: Double)
    case suggestContact(name: String, hint: String?)
    case systemOperation(category: String, displayName: String)
    case needsManualPick(reason: String, topMerchantId: String?,
                         topName: String?, topScore: Double?)
}

/// A row of an import in progress. Everything is Codable for JSON persistence.
struct ImportSessionRow: Identifiable, Codable, Hashable {
    let id: UUID
    /// Row number in the source CSV (1-indexed, excluding the header).
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
    /// Cluster identifier (to group similar labels). Optional.
    var clusterId: String?
    /// Id of a payee CREATED by this row during the session (via "Create a new payee").
    /// Lets us offer to delete it if the session is canceled (cleanup of ghost payees).
    /// nil = no payee created by this row (link to an existing payee, or not yet decided).
    var createdPayeeId: Int? = nil
    /// Source file, when a session aggregates SEVERAL files.
    /// `nil` for a single-file session (the info is then in
    /// `ImportSession.sourceFile`).
    ///
    /// Optional property with a default value: the synthesized `Codable`
    /// decodes it as `decodeIfPresent`, so already-persisted `rows_json` (active
    /// sessions from a previous version) reload without a migration.
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

/// Heavyweight representation of a session: all of its content. For editing.
///
/// ⚠️ The content depends on the DESTINATION (`destination` column, migration v45):
///   • `.transactions` → `rows`, which carry each row's resolution state
///     (assigned payee, user action);
///   • `.investments`  → `batch`, the pipeline's raw output.
///
/// The two don't merge: a transaction row carries user decisions
/// that an `ImportElement` has no business carrying — that's the
/// boundary between ingestion (redesigned) and resolution (unchanged).
struct ImportSession: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: ImportSessionStatus
    var sourceFile: String?
    var accountId: Int?
    var destination: ImportDestination
    var rows: [ImportSessionRow]
    /// Pipeline output, for an investments session.
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

/// Lightweight representation used for the banner / the global index.
/// Avoids loading the whole JSON when all that's needed is showing "N rows remaining".
struct ImportSessionSummary: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let status: ImportSessionStatus
    let sourceFile: String?
    let accountId: Int?
    let totalRows: Int
    let pendingRows: Int
    /// Where this session is headed — this decides which review screen to reopen.
    var destination: ImportDestination = .transactions
}

// MARK: - ColumnMapping

/// A CSV's column mapping. Indexed by signature (concatenation of the headers).
struct ColumnMapping: Codable, Hashable {
    let headerSignature: String
    var dateColumnIndex: Int
    var amountColumnIndex: Int
    var labelColumnIndex: Int
    var separator: String        // ";", ",", "\t"
    var dateFormat: String?      // "dd/MM/yyyy", "yyyy-MM-dd", etc. (nil = auto-detection)
    var amountDecimal: String    // "," ou "."
}

/// Stable signature of a CSV header: every name lowercased with accents stripped, joined with "|".
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
