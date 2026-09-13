import Foundation
import SQLite3

// MARK: - PatrimoineRepository
//
// CRUD for the Patrimoine module's 3 tables (see migration v37):
//   • patrimoine_real_estate
//   • patrimoine_loans
//   • patrimoine_assets
//
// **Plain CRUD**. No linking resolution here: `resolveValue(for:)`
// lives elsewhere (Movable Assets & Cash), where it's needed for the picker.
// Same for `LoanCalculator`: a pure Swift structure added separately.
//
// A pattern aligned with InvestmentRepository (a struct + a read-only `query` + `writeSingle`).

private let SQLITE_TRANSIENT_PATRIMOINE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct PatrimoineRepository {

    private let store: SQLiteStore

    /// The default value targets the app's database: existing call sites
    /// don't have to change.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Real estate — CRUD

    func fetchRealEstate() -> [PatrimoineRealEstate] {
        query { db in
            let sql = """
            SELECT id, name, purchase_price, purchase_date, current_value,
                   COALESCE(estimated_at, ''), COALESCE(address, ''),
                   COALESCE(notes, ''), created_at
            FROM patrimoine_real_estate
            ORDER BY name COLLATE NOCASE;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [PatrimoineRealEstate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let estimatedRaw = string(from: stmt, index: 5)
                let addressRaw = string(from: stmt, index: 6)
                let notesRaw = string(from: stmt, index: 7)
                results.append(PatrimoineRealEstate(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    purchasePrice: sqlite3_column_double(stmt, 2),
                    purchaseDate: dateFormatter.date(from: string(from: stmt, index: 3)) ?? Date(),
                    currentValue: sqlite3_column_double(stmt, 4),
                    estimatedAt: estimatedRaw.isEmpty ? nil : dateFormatter.date(from: estimatedRaw),
                    address: addressRaw.isEmpty ? nil : addressRaw,
                    notes: notesRaw.isEmpty ? nil : notesRaw,
                    createdAt: dateFormatter.date(from: string(from: stmt, index: 8)) ?? Date()
                ))
            }
            return results
        } ?? []
    }

    @discardableResult
    func addRealEstate(name: String, purchasePrice: Double, purchaseDate: Date,
                       currentValue: Double, estimatedAt: Date?, address: String?,
                       notes: String?) -> Bool {
        let sql = """
        INSERT INTO patrimoine_real_estate
            (name, purchase_price, purchase_date, current_value, estimated_at, address, notes, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 2, purchasePrice)
            sqlite3_bind_text(stmt, 3, dateFormatter.string(from: purchaseDate), -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 4, currentValue)
            if let estimatedAt {
                sqlite3_bind_text(stmt, 5, dateFormatter.string(from: estimatedAt), -1, SQLITE_TRANSIENT_PATRIMOINE)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            bindOptionalText(stmt, 6, address)
            bindOptionalText(stmt, 7, notes)
            sqlite3_bind_text(stmt, 8, dateFormatter.string(from: Date()), -1, SQLITE_TRANSIENT_PATRIMOINE)
        }
    }

    @discardableResult
    func updateRealEstate(_ item: PatrimoineRealEstate) -> Bool {
        let sql = """
        UPDATE patrimoine_real_estate
        SET name = ?, purchase_price = ?, purchase_date = ?, current_value = ?,
            estimated_at = ?, address = ?, notes = ?
        WHERE id = ?;
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, item.name, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 2, item.purchasePrice)
            sqlite3_bind_text(stmt, 3, dateFormatter.string(from: item.purchaseDate), -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 4, item.currentValue)
            if let est = item.estimatedAt {
                sqlite3_bind_text(stmt, 5, dateFormatter.string(from: est), -1, SQLITE_TRANSIENT_PATRIMOINE)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            bindOptionalText(stmt, 6, item.address)
            bindOptionalText(stmt, 7, item.notes)
            sqlite3_bind_int(stmt, 8, Int32(item.id))
        }
    }

    @discardableResult
    func deleteRealEstate(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM patrimoine_real_estate WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    // MARK: - Loans — CRUD

    func fetchLoans() -> [PatrimoineLoan] {
        query { db in
            // insurance_monthly added in v38 — no COALESCE since it's NOT NULL DEFAULT 0
            // on the SQL side (existing pre-v38 databases → 0 by default after the ALTER).
            let sql = """
            SELECT id, name, loan_type, principal, annual_rate,
                   duration_months, deferral_months, start_date,
                   linked_real_estate_id, COALESCE(notes, ''), created_at,
                   insurance_monthly
            FROM patrimoine_loans
            ORDER BY name COLLATE NOCASE;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [PatrimoineLoan] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let typeRaw = string(from: stmt, index: 2)
                let notesRaw = string(from: stmt, index: 9)
                let linkedRealEstateId: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(stmt, 8))
                results.append(PatrimoineLoan(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    loanType: LoanType(rawValue: typeRaw) ?? .amortizing,
                    principal: sqlite3_column_double(stmt, 3),
                    annualRate: sqlite3_column_double(stmt, 4),
                    durationMonths: Int(sqlite3_column_int(stmt, 5)),
                    deferralMonths: Int(sqlite3_column_int(stmt, 6)),
                    startDate: dateFormatter.date(from: string(from: stmt, index: 7)) ?? Date(),
                    insuranceMonthly: sqlite3_column_double(stmt, 11),
                    linkedRealEstateId: linkedRealEstateId,
                    notes: notesRaw.isEmpty ? nil : notesRaw,
                    createdAt: dateFormatter.date(from: string(from: stmt, index: 10)) ?? Date()
                ))
            }
            return results
        } ?? []
    }

    @discardableResult
    func addLoan(name: String, loanType: LoanType, principal: Double,
                 annualRate: Double, durationMonths: Int, deferralMonths: Int,
                 startDate: Date, insuranceMonthly: Double, linkedRealEstateId: Int?,
                 notes: String?) -> Bool {
        let sql = """
        INSERT INTO patrimoine_loans
            (name, loan_type, principal, annual_rate, duration_months,
             deferral_months, start_date, linked_real_estate_id, notes, created_at,
             insurance_monthly)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_text(stmt, 2, loanType.rawValue, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 3, principal)
            sqlite3_bind_double(stmt, 4, annualRate)
            sqlite3_bind_int(stmt, 5, Int32(durationMonths))
            sqlite3_bind_int(stmt, 6, Int32(deferralMonths))
            sqlite3_bind_text(stmt, 7, dateFormatter.string(from: startDate), -1, SQLITE_TRANSIENT_PATRIMOINE)
            if let linkedRealEstateId {
                sqlite3_bind_int(stmt, 8, Int32(linkedRealEstateId))
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            bindOptionalText(stmt, 9, notes)
            sqlite3_bind_text(stmt, 10, dateFormatter.string(from: Date()), -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 11, insuranceMonthly)
        }
    }

    @discardableResult
    func updateLoan(_ loan: PatrimoineLoan) -> Bool {
        let sql = """
        UPDATE patrimoine_loans
        SET name = ?, loan_type = ?, principal = ?, annual_rate = ?,
            duration_months = ?, deferral_months = ?, start_date = ?,
            linked_real_estate_id = ?, notes = ?, insurance_monthly = ?
        WHERE id = ?;
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, loan.name, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_text(stmt, 2, loan.loanType.rawValue, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_double(stmt, 3, loan.principal)
            sqlite3_bind_double(stmt, 4, loan.annualRate)
            sqlite3_bind_int(stmt, 5, Int32(loan.durationMonths))
            sqlite3_bind_int(stmt, 6, Int32(loan.deferralMonths))
            sqlite3_bind_text(stmt, 7, dateFormatter.string(from: loan.startDate), -1, SQLITE_TRANSIENT_PATRIMOINE)
            if let linked = loan.linkedRealEstateId {
                sqlite3_bind_int(stmt, 8, Int32(linked))
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            bindOptionalText(stmt, 9, loan.notes)
            sqlite3_bind_double(stmt, 10, loan.insuranceMonthly)
            sqlite3_bind_int(stmt, 11, Int32(loan.id))
        }
    }

    @discardableResult
    func deleteLoan(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM patrimoine_loans WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    // MARK: - Assets — CRUD

    func fetchAssets() -> [PatrimoineAsset] {
        query { db in
            let sql = """
            SELECT id, name, asset_kind, linked_account_id, linked_investment_account_id,
                   manual_value, last_known_value, COALESCE(notes, ''), created_at
            FROM patrimoine_assets
            ORDER BY name COLLATE NOCASE;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [PatrimoineAsset] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let kindRaw = string(from: stmt, index: 2)
                let notesRaw = string(from: stmt, index: 7)
                let linkedAccountId: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(stmt, 3))
                let linkedInvestmentAccountId: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(stmt, 4))
                results.append(PatrimoineAsset(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: string(from: stmt, index: 1),
                    assetKind: AssetKind(rawValue: kindRaw) ?? .other,
                    linkedAccountId: linkedAccountId,
                    linkedInvestmentAccountId: linkedInvestmentAccountId,
                    manualValue: sqlite3_column_double(stmt, 5),
                    lastKnownValue: sqlite3_column_double(stmt, 6),
                    notes: notesRaw.isEmpty ? nil : notesRaw,
                    createdAt: dateFormatter.date(from: string(from: stmt, index: 8)) ?? Date()
                ))
            }
            return results
        } ?? []
    }

    @discardableResult
    func addAsset(name: String, assetKind: AssetKind, linkedAccountId: Int?,
                  linkedInvestmentAccountId: Int?, manualValue: Double,
                  lastKnownValue: Double, notes: String?) -> Bool {
        let sql = """
        INSERT INTO patrimoine_assets
            (name, asset_kind, linked_account_id, linked_investment_account_id,
             manual_value, last_known_value, notes, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_text(stmt, 2, assetKind.rawValue, -1, SQLITE_TRANSIENT_PATRIMOINE)
            if let linkedAccountId {
                sqlite3_bind_int(stmt, 3, Int32(linkedAccountId))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let linkedInvestmentAccountId {
                sqlite3_bind_int(stmt, 4, Int32(linkedInvestmentAccountId))
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, manualValue)
            sqlite3_bind_double(stmt, 6, lastKnownValue)
            bindOptionalText(stmt, 7, notes)
            sqlite3_bind_text(stmt, 8, dateFormatter.string(from: Date()), -1, SQLITE_TRANSIENT_PATRIMOINE)
        }
    }

    @discardableResult
    func updateAsset(_ asset: PatrimoineAsset) -> Bool {
        let sql = """
        UPDATE patrimoine_assets
        SET name = ?, asset_kind = ?, linked_account_id = ?, linked_investment_account_id = ?,
            manual_value = ?, last_known_value = ?, notes = ?
        WHERE id = ?;
        """
        return writeSingle(sql: sql) { [self] stmt in
            sqlite3_bind_text(stmt, 1, asset.name, -1, SQLITE_TRANSIENT_PATRIMOINE)
            sqlite3_bind_text(stmt, 2, asset.assetKind.rawValue, -1, SQLITE_TRANSIENT_PATRIMOINE)
            if let linked = asset.linkedAccountId {
                sqlite3_bind_int(stmt, 3, Int32(linked))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let linkedInv = asset.linkedInvestmentAccountId {
                sqlite3_bind_int(stmt, 4, Int32(linkedInv))
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, asset.manualValue)
            sqlite3_bind_double(stmt, 6, asset.lastKnownValue)
            bindOptionalText(stmt, 7, asset.notes)
            sqlite3_bind_int(stmt, 8, Int32(asset.id))
        }
    }

    @discardableResult
    func deleteAsset(id: Int) -> Bool {
        writeSingle(sql: "DELETE FROM patrimoine_assets WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    /// Updates only `last_known_value` — used after every dynamic resolution
    /// of a linked asset's value. Avoids touching the other fields.
    @discardableResult
    func updateLastKnownValue(assetId: Int, value: Double) -> Bool {
        writeSingle(sql: "UPDATE patrimoine_assets SET last_known_value = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, value)
            sqlite3_bind_int(stmt, 2, Int32(assetId))
        }
    }

    // MARK: - Linking conflict detection

    /// Returns the `PatrimoineAsset.id` that already occupies this link, if there is one.
    /// Used by the forms to prevent double-counting before the INSERT,
    /// with an explicit error message (the SQL UNIQUE INDEX is the second line
    /// of defense — it triggers an sqlite3_step failure, but with no user-friendly context).
    func assetIdLinkedTo(accountId: Int?, investmentAccountId: Int?, excludingAssetId: Int?) -> Int? {
        guard accountId != nil || investmentAccountId != nil else { return nil }
        return query { db in
            var sql = "SELECT id FROM patrimoine_assets WHERE 1=1"
            if accountId != nil {
                sql += " AND linked_account_id = ?"
            }
            if investmentAccountId != nil {
                sql += " AND linked_investment_account_id = ?"
            }
            if excludingAssetId != nil {
                sql += " AND id != ?"
            }
            sql += " LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            var col: Int32 = 1
            if let a = accountId {
                sqlite3_bind_int(stmt, col, Int32(a)); col += 1
            }
            if let i = investmentAccountId {
                sqlite3_bind_int(stmt, col, Int32(i)); col += 1
            }
            if let ex = excludingAssetId {
                sqlite3_bind_int(stmt, col, Int32(ex))
            }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : nil
        } ?? nil
    }

    // MARK: - Helpers internes

    private func query<T>(_ block: (OpaquePointer) -> T) -> T? { store.read(block) }

    @discardableResult
    private func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        store.writeSingle(sql: sql, bind: bind)
    }


    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value, !v.isEmpty {
            sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT_PATRIMOINE)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
