import Foundation
import SQLite3

private let SQLITE_TRANSIENT_APPLEPAY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Une dépense Apple Pay déposée par l'automatisation Raccourcis, en attente
/// de résolution — jamais créée directement par l'utilisateur.
struct PendingApplePayEntry: Identifiable {
    enum Status: String {
        /// Déposée, pas encore traitée.
        case pending
        /// Rapprochée d'une transaction arrivée par import bancaire (relevé
        /// CSV/PDF/OFX). Pas encore livré — cf. AXE en cours.
        case matched
        /// Écartée par l'utilisateur.
        case dismissed
    }

    let id: Int
    var card: String?
    /// Toujours négatif (dépense) — cf. `PendingApplePayRepository.addEntry`.
    var amount: Double
    var merchant: String
    var status: Status
    var matchedTransactionId: Int?
    var createdAt: Date
}

/// CRUD pour `pending_apple_pay_entries` (migration v49).
///
/// Alimentée UNIQUEMENT par `ImportTransactionApplePayEntityIntent`
/// (automatisation personnelle Raccourcis « Apple Pay », `openAppWhenRun =
/// false` — s'exécute sans jamais afficher l'app). Table locale, jamais
/// synchronisée (cf. `SyncSchema.swift`) : chaque appareil reçoit ses propres
/// notifications Apple Pay, rien à réconcilier entre appareils.
struct PendingApplePayRepository {

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites
    /// d'appel existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    // Propriété d'INSTANCE, pas `static` : un `ISO8601DateFormatter` n'est pas
    // `Sendable`, et un `static let` en ferait une variable globale mutable
    // partagée, rejetée par la concurrence stricte Swift 6 (cf. LiveSyncRepository).
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Écriture

    /// Dépose une entrée en attente. `amount` peut arriver positif (valeur
    /// brute fournie par le déclencheur Raccourcis « Apple Pay ») : on la
    /// normalise en négatif ici, une bonne fois, pour rester compatible avec
    /// la convention du reste de l'app (`transactions.amount < 0` = dépense)
    /// sans que chaque futur lecteur (budget, notifications) ait à y penser.
    @discardableResult
    func addEntry(card: String?, amount: Double, merchant: String) -> Bool {
        let now = isoFormatter.string(from: Date())
        return store.writeSingle(sql: """
            INSERT INTO pending_apple_pay_entries (card, amount, merchant, status, created_at)
            VALUES (?, ?, ?, 'pending', ?);
            """) { stmt in
            if let card, !card.isEmpty {
                sqlite3_bind_text(stmt, 1, card, -1, SQLITE_TRANSIENT_APPLEPAY)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, -abs(amount))
            sqlite3_bind_text(stmt, 3, merchant, -1, SQLITE_TRANSIENT_APPLEPAY)
            sqlite3_bind_text(stmt, 4, now, -1, SQLITE_TRANSIENT_APPLEPAY)
        }
    }

    // MARK: - Mise à jour

    /// Change le statut d'une entrée (écarter manuellement depuis la liste).
    @discardableResult
    func updateStatus(id: Int, to status: PendingApplePayEntry.Status) -> Bool {
        store.writeSingle(sql: "UPDATE pending_apple_pay_entries SET status = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT_APPLEPAY)
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    /// Corrige le montant d'une entrée déposée sans montant connu (cf.
    /// `ImportTransactionApplePayEntityIntent` — stockée à 0 le temps que
    /// l'utilisateur la corrige depuis `PendingApplePayListView`).
    /// Normalisée en négatif comme `addEntry`, même convention.
    @discardableResult
    func updateAmount(id: Int, amount: Double) -> Bool {
        store.writeSingle(sql: "UPDATE pending_apple_pay_entries SET amount = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, -abs(amount))
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    // MARK: - Suppression

    /// Supprime définitivement les entrées déposées avant `cutoff`, tous
    /// statuts confondus (`pending` comme `dismissed` — rien ne les efface
    /// jamais autrement, elles s'accumuleraient indéfiniment sinon). Geste
    /// manuel, déclenché par l'utilisateur depuis les réglages. Renvoie le
    /// nombre de lignes supprimées pour le feedback UI.
    @discardableResult
    func purgeEntries(olderThan cutoff: Date) -> Int {
        store.write { db -> Int in
            var stmt: OpaquePointer?
            let sql = "DELETE FROM pending_apple_pay_entries WHERE created_at < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, isoFormatter.string(from: cutoff), -1, SQLITE_TRANSIENT_APPLEPAY)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        } ?? 0
    }

    // MARK: - Lecture

    /// Entrées du statut donné (toutes si `nil`), plus récentes d'abord.
    func fetchEntries(status: PendingApplePayEntry.Status? = nil) -> [PendingApplePayEntry] {
        store.read { db -> [PendingApplePayEntry] in
            let sql = status != nil
                ? "SELECT id, card, amount, merchant, status, matched_transaction_id, created_at FROM pending_apple_pay_entries WHERE status = ? ORDER BY created_at DESC;"
                : "SELECT id, card, amount, merchant, status, matched_transaction_id, created_at FROM pending_apple_pay_entries ORDER BY created_at DESC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let status {
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT_APPLEPAY)
            }

            var out: [PendingApplePayEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let entry = self.row(from: stmt) else { continue }
                out.append(entry)
            }
            return out
        } ?? []
    }

    /// Somme des montants encore `pending` depuis `since` — support direct
    /// d'une future alerte par période ("X € Apple Pay non catégorisé cette
    /// semaine"). Négatif (convention dépense) ; le futur appelant applique
    /// `abs(...)` pour l'affichage.
    func pendingTotal(since: Date) -> Double {
        store.read { db -> Double in
            var stmt: OpaquePointer?
            let sql = "SELECT COALESCE(SUM(amount), 0) FROM pending_apple_pay_entries WHERE status = 'pending' AND created_at >= ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, isoFormatter.string(from: since), -1, SQLITE_TRANSIENT_APPLEPAY)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_double(stmt, 0)
        } ?? 0
    }

    private func row(from stmt: OpaquePointer?) -> PendingApplePayEntry? {
        guard let stmt else { return nil }
        let id = Int(sqlite3_column_int(stmt, 0))
        let card = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : string(from: stmt, index: 1)
        let amount = sqlite3_column_double(stmt, 2)
        let merchant = string(from: stmt, index: 3)
        guard let status = PendingApplePayEntry.Status(rawValue: string(from: stmt, index: 4)) else { return nil }
        let matchedTransactionId = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int(stmt, 5))
        let createdAt = isoFormatter.date(from: string(from: stmt, index: 6)) ?? Date()
        return PendingApplePayEntry(
            id: id, card: card, amount: amount, merchant: merchant,
            status: status, matchedTransactionId: matchedTransactionId, createdAt: createdAt
        )
    }
}
