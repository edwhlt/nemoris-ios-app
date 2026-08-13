import Foundation
import SQLite3
import NemorisEngine

/// Résultat d'une résolution moteur → payee côté application.
enum TierResolution {
    /// Un payee existant correspond directement (même engine_merchant_id, même city).
    /// L'app peut affecter transaction.payee_id = matched.id automatiquement.
    case matched(payee: ResolvedPayee, score: Double)

    /// Le moteur a identifié un merchant canonique connu, mais aucun payee local n'existe
    /// pour cet emplacement → on propose la création d'un nouveau payee, éventuellement
    /// rattaché à un groupe existant si l'utilisateur a déjà des payees pour cette marque.
    case suggestCreate(suggestion: PayeeSuggestion)

    /// P2P détecté → on propose un payee "personne" sans lien engine.
    case suggestContact(name: String, hint: String)

    /// Opération bancaire interne (RETRAIT DAB, frais, etc.) → pas de payee classique
    /// nécessaire. L'app peut utiliser une catégorie système ou laisser l'utilisateur décider.
    case systemOperation(category: NemorisEngine.SystemCategory, displayName: String)

    /// Le moteur n'a rien d'utilisable → l'utilisateur doit choisir ou créer manuellement.
    case needsManualPick(reason: String, topCandidate: TopCandidate?)
}

struct ResolvedPayee: Hashable {
    let id: Int
    let name: String
    let city: String?
    let groupId: Int?
    let engineMerchantId: String?
}

struct PayeeSuggestion: Hashable {
    let displayName: String          // "Carrefour Market — Oullins"
    let canonicalName: String        // "carrefour market" (technique côté engine)
    let engineMerchantId: String     // "carrefour_market"
    let city: String?
    let country: String?
    let existingGroup: ResolvedPayeeGroup?
    let suggestedGroupName: String?  // si pas de groupe et plusieurs payees similaires existent
}

struct ResolvedPayeeGroup: Hashable {
    let id: Int
    let displayName: String
    let engineMerchantId: String?
}

struct TopCandidate: Hashable {
    let canonicalName: String
    let score: Double
}

/// Adaptateur entre `NemorisEngine.TransactionEngine` et la table `payees` de l'app.
///
/// Le moteur sait identifier des marques canoniques (ex `"carrefour_market"`) et extraire
/// une ville. Cette classe traduit ça en payee_id selon les règles métier de l'app :
///
///   - même engine_merchant_id + même city            → match auto
///   - même engine_merchant_id, city différente       → suggérer un nouveau payee dans le groupe
///   - engine_merchant_id inconnu de l'app            → suggérer création d'un payee (+ groupe ?)
///   - .contact / .system / .unknown                  → branches dédiées
@MainActor
final class TierResolver {

    private let engine: TransactionEngine
    private let dbPath: String

    init(engine: TransactionEngine, dbPath: String) {
        self.engine = engine
        self.dbPath = dbPath
    }

    // MARK: - Résolution

    /// Résout un libellé brut bancaire en une décision actionnable côté UI.
    func resolve(rawLabel: String) -> TierResolution {
        let resolved: ResolvedTransaction
        do {
            resolved = try engine.resolve(rawLabel)
        } catch {
            return .needsManualPick(reason: "engine_error: \(error)", topCandidate: nil)
        }

        switch resolved.decision {
        case .system:
            return .systemOperation(
                category: resolved.parsed.systemCategory ?? .unknown,
                displayName: resolved.parsed.systemDisplayName ?? "Opération bancaire"
            )

        case .contact:
            let name = resolved.contactDisplayName ?? resolved.p2pMatch?.nameCandidate ?? "(contact)"
            let hint = "Virement détecté (\(resolved.p2pMatch?.kind.rawValue ?? "P2P"))"
            return .suggestContact(name: name, hint: hint)

        case .autoValidated, .suggested:
            guard let top = resolved.topCandidate else {
                return .needsManualPick(reason: "no_top_candidate", topCandidate: nil)
            }
            return matchOrSuggest(
                engineMerchantId: top.merchantId,
                canonicalName: top.canonicalName,
                city: resolved.parsed.cityCandidate,
                country: resolved.parsed.countryCandidate,
                score: top.score
            )

        case .picker, .unknown:
            let top = resolved.topCandidate.map {
                TopCandidate(canonicalName: $0.canonicalName, score: $0.score)
            }
            return .needsManualPick(reason: "low_confidence", topCandidate: top)
        }
    }

    /// Lookup d'un payee local par (engine_merchant_id, city) ; à défaut suggestion de création.
    private func matchOrSuggest(
        engineMerchantId: String,
        canonicalName: String,
        city: String?,
        country: String?,
        score: Double
    ) -> TierResolution {
        if let exact = findPayee(engineMerchantId: engineMerchantId, city: city) {
            return .matched(payee: exact, score: score)
        }

        // Cherche un groupe existant pour cette marque
        let existingGroup = findGroup(engineMerchantId: engineMerchantId)
        // Combien d'instances déjà ouvertes pour cette marque ?
        let instancesForBrand = countPayees(engineMerchantId: engineMerchantId)
        let suggestedGroupName: String? = (existingGroup == nil && instancesForBrand >= 1)
            ? canonicalName.capitalized
            : nil

        let displayName = formatDisplayName(canonicalName: canonicalName, city: city)
        let suggestion = PayeeSuggestion(
            displayName: displayName,
            canonicalName: canonicalName,
            engineMerchantId: engineMerchantId,
            city: city,
            country: country,
            existingGroup: existingGroup,
            suggestedGroupName: suggestedGroupName
        )
        return .suggestCreate(suggestion: suggestion)
    }

    // MARK: - Création (appelée depuis l'UI après confirmation user)

    /// Crée un payee (et son groupe si demandé) et retourne son id. À appeler depuis l'UI
    /// après que l'utilisateur a validé la suggestion.
    @discardableResult
    func commitNewPayee(_ suggestion: PayeeSuggestion, useGroup: Bool) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        var groupId: Int? = suggestion.existingGroup?.id
        if useGroup, groupId == nil, let groupName = suggestion.suggestedGroupName {
            groupId = insertGroup(db: db, displayName: groupName, engineMerchantId: suggestion.engineMerchantId)
        }

        return insertPayee(db: db, suggestion: suggestion, groupId: groupId)
    }

    /// Crée un payee "personne" (contact P2P) sans lien engine.
    @discardableResult
    func commitContactPayee(name: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "INSERT INTO payees (name, custom) VALUES (?, 1)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    // MARK: - SQLite helpers

    private func findPayee(engineMerchantId: String, city: String?) -> ResolvedPayee? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let sql: String
        if city != nil {
            sql = """
                SELECT id, COALESCE(name,''), city, group_id, engine_merchant_id
                FROM payees
                WHERE engine_merchant_id = ?
                  AND (city = ? OR (city IS NULL AND ? IS NULL))
                LIMIT 1
            """
        } else {
            sql = """
                SELECT id, COALESCE(name,''), city, group_id, engine_merchant_id
                FROM payees
                WHERE engine_merchant_id = ? AND city IS NULL
                LIMIT 1
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, engineMerchantId, -1, sqliteTransient)
        if let c = city {
            sqlite3_bind_text(stmt, 2, c, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, c, -1, sqliteTransient)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = Int(sqlite3_column_int(stmt, 0))
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let cityOut = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
        let groupId = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
        let emid = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
        return ResolvedPayee(id: id, name: name, city: cityOut, groupId: groupId, engineMerchantId: emid)
    }

    private func findGroup(engineMerchantId: String) -> ResolvedPayeeGroup? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "SELECT id, display_name, engine_merchant_id FROM payee_groups WHERE engine_merchant_id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, engineMerchantId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = Int(sqlite3_column_int(stmt, 0))
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let emid = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
        return ResolvedPayeeGroup(id: id, displayName: name, engineMerchantId: emid)
    }

    private func countPayees(engineMerchantId: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM payees WHERE engine_merchant_id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, engineMerchantId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func insertGroup(db: OpaquePointer, displayName: String, engineMerchantId: String) -> Int? {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO payee_groups (display_name, engine_merchant_id) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, displayName, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, engineMerchantId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func insertPayee(db: OpaquePointer, suggestion: PayeeSuggestion, groupId: Int?) -> Int? {
        let sql = """
            INSERT INTO payees (name, city, country, engine_merchant_id, group_id, custom)
            VALUES (?, ?, ?, ?, ?, 0)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, suggestion.displayName, -1, sqliteTransient)
        bindOptionalText(stmt, 2, suggestion.city)
        bindOptionalText(stmt, 3, suggestion.country)
        sqlite3_bind_text(stmt, 4, suggestion.engineMerchantId, -1, sqliteTransient)
        if let gid = groupId {
            sqlite3_bind_int(stmt, 5, Int32(gid))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func bindOptionalText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func formatDisplayName(canonicalName: String, city: String?) -> String {
        let pretty = canonicalName
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        if let c = city, !c.isEmpty {
            let cityCap = c.prefix(1).uppercased() + c.dropFirst()
            return "\(pretty) — \(cityCap)"
        }
        return pretty
    }
}

/// SQLITE_TRANSIENT pour bind_text : oblige SQLite à copier la string Swift en interne.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
