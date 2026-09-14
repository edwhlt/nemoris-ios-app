import Foundation
import Testing
@testable import Nemoris

/// The SQL Console / AI assistant safeguard: a statement that would
/// modify the SCHEMA must be blocked, one that modifies DATA must
/// require confirmation, everything else (reads, transactions, maintenance)
/// runs without friction.
@Suite("SQLStatementGuard")
struct SQLStatementGuardTests {

    // MARK: - Reads, no friction

    @Test("SELECT simple est une query")
    func selectSimple() {
        let c = SQLStatementGuard.classify("SELECT * FROM payees WHERE id = 1")
        #expect(c.kind == .query)
        #expect(c.keyword == "SELECT")
    }

    @Test("EXPLAIN et PRAGMA de lecture sont des query")
    func explainEtPragmaLecture() {
        #expect(SQLStatementGuard.classify("EXPLAIN QUERY PLAN SELECT 1").kind == .query)
        #expect(SQLStatementGuard.classify("PRAGMA table_info(payees)").kind == .query)
        #expect(SQLStatementGuard.classify("PRAGMA user_version").kind == .query)
    }

    @Test("VACUUM / ANALYZE / REINDEX sont de la maintenance, pas un blocage")
    func maintenance() {
        #expect(SQLStatementGuard.classify("VACUUM").kind == .maintenance)
        #expect(SQLStatementGuard.classify("ANALYZE").kind == .maintenance)
        #expect(SQLStatementGuard.classify("REINDEX idx_payees_uuid").kind == .maintenance)
    }

    @Test("BEGIN / COMMIT / ROLLBACK sont du contrôle transactionnel")
    func transactionControl() {
        #expect(SQLStatementGuard.classify("BEGIN").kind == .transactionControl)
        #expect(SQLStatementGuard.classify("COMMIT").kind == .transactionControl)
        #expect(SQLStatementGuard.classify("ROLLBACK").kind == .transactionControl)
    }

    // MARK: - Data: confirmation, never a block

    @Test("INSERT / UPDATE / DELETE / REPLACE demandent confirmation, jamais un blocage")
    func dataModification() {
        for sql in [
            "INSERT INTO payees (name) VALUES ('Test')",
            "UPDATE payees SET name = 'X' WHERE id = 1",
            "DELETE FROM transactions WHERE id = 5",
            "REPLACE INTO tags (id, name) VALUES (1, 'x')"
        ] {
            let c = SQLStatementGuard.classify(sql)
            #expect(c.kind == .dataModification, "\(sql) devrait être dataModification")
            #expect(c.kind.requiresDataModificationConfirmation)
            #expect(!c.kind.isBlockedBySchemaGuard)
        }
    }

    @Test("La cible d'un INSERT/UPDATE/DELETE est extraite pour l'affichage")
    func cibleExtraite() {
        #expect(SQLStatementGuard.classify("INSERT INTO payees (name) VALUES ('x')").target == "payees")
        #expect(SQLStatementGuard.classify("INSERT OR IGNORE INTO payees (name) VALUES ('x')").target == "payees")
        #expect(SQLStatementGuard.classify("UPDATE payees SET name = 'x'").target == "payees")
        #expect(SQLStatementGuard.classify("DELETE FROM transactions WHERE id = 1").target == "transactions")
    }

    // MARK: - Schema: blocked, never just a confirmation

    @Test("CREATE / ALTER / DROP sont bloqués")
    func schemaModificationBloquee() {
        for sql in [
            "CREATE TABLE foo (id INTEGER)",
            "ALTER TABLE payees ADD COLUMN foo TEXT",
            "DROP TABLE payees",
            "DROP INDEX IF EXISTS idx_payees_uuid"
        ] {
            let c = SQLStatementGuard.classify(sql)
            #expect(c.kind == .schemaModification, "\(sql) devrait être schemaModification")
            #expect(c.kind.isBlockedBySchemaGuard)
            #expect(!c.kind.requiresDataModificationConfirmation)
        }
    }

    @Test("ATTACH / DETACH sont bloqués (base entière rattachée)")
    func attachDetachBloques() {
        #expect(SQLStatementGuard.classify("ATTACH DATABASE '/tmp/x.sqlite' AS foo").kind == .schemaModification)
        #expect(SQLStatementGuard.classify("DETACH DATABASE foo").kind == .schemaModification)
    }

    @Test("La cible d'un CREATE/ALTER/DROP est extraite pour l'affichage")
    func cibleDDLExtraite() {
        #expect(SQLStatementGuard.classify("CREATE TABLE IF NOT EXISTS foo (id INTEGER)").target == "foo")
        #expect(SQLStatementGuard.classify("ALTER TABLE payees ADD COLUMN foo TEXT").target == "payees")
        #expect(SQLStatementGuard.classify("DROP TABLE IF EXISTS payees").target == "payees")
    }

    @Test("PRAGMA user_version = X est un déguisement de modification de schéma")
    func pragmaUserVersionEcriture() {
        // DatabaseManager relies on PRAGMA user_version to know which
        // migrations to apply — overwriting it by hand desynchronizes the app from
        // its own schema, exactly like an untracked ALTER TABLE.
        let c = SQLStatementGuard.classify("PRAGMA user_version = 999")
        #expect(c.kind == .schemaModification)
    }

    @Test("PRAGMA journal_mode/foreign_keys en écriture sont bloqués, en lecture non")
    func pragmaEcritureVsLecture() {
        #expect(SQLStatementGuard.classify("PRAGMA journal_mode = WAL").kind == .schemaModification)
        #expect(SQLStatementGuard.classify("PRAGMA foreign_keys = OFF").kind == .schemaModification)
        #expect(SQLStatementGuard.classify("PRAGMA foreign_keys").kind == .query)
    }

    @Test("PRAGMA wal_checkpoint/optimize sans '=' sont bloqués (effet de bord réel)")
    func pragmaSansAssignationMaisDangereux() {
        #expect(SQLStatementGuard.classify("PRAGMA wal_checkpoint(TRUNCATE)").kind == .schemaModification)
        #expect(SQLStatementGuard.classify("PRAGMA optimize").kind == .schemaModification)
    }

    // MARK: - Commentaires et casse

    @Test("Les commentaires -- et /* */ avant le mot-clé sont ignorés")
    func commentairesIgnores() {
        let sql = """
        -- Nettoyage des vieux tiers
        /* voir ticket #42 */
        DELETE FROM payees WHERE id = 1
        """
        let c = SQLStatementGuard.classify(sql)
        #expect(c.kind == .dataModification)
        #expect(c.keyword == "DELETE")
    }

    @Test("La casse n'a pas d'importance")
    func casseIgnoree() {
        #expect(SQLStatementGuard.classify("select * from payees").kind == .query)
        #expect(SQLStatementGuard.classify("Drop Table payees").kind == .schemaModification)
        #expect(SQLStatementGuard.classify("insert into payees (name) values ('x')").kind == .dataModification)
    }

    // MARK: - CTE (WITH ...)

    @Test("WITH ... SELECT reste une query")
    func cteSelect() {
        let sql = "WITH recents AS (SELECT * FROM transactions LIMIT 10) SELECT * FROM recents"
        #expect(SQLStatementGuard.classify(sql).kind == .query)
    }

    @Test("WITH ... DELETE est une modification de données, pas une query")
    func cteDelete() {
        let sql = "WITH cibles AS (SELECT id FROM payees WHERE custom = 0) DELETE FROM payees WHERE id IN (SELECT id FROM cibles)"
        let c = SQLStatementGuard.classify(sql)
        #expect(c.kind == .dataModification)
        #expect(c.keyword == "DELETE")
    }

    @Test("WITH ... DROP reste bloqué comme n'importe quel DROP")
    func cteDrop() {
        // An adversarial case: a CTE must never be used to disguise a DDL statement.
        let sql = "WITH x AS (SELECT 1) DROP TABLE payees"
        #expect(SQLStatementGuard.classify(sql).kind == .schemaModification)
    }

    @Test("WITH à plusieurs CTE trouve le bon verbe final")
    func cteMultiple() {
        let sql = "WITH a AS (SELECT 1), b AS (SELECT 2) UPDATE payees SET name = 'x'"
        let c = SQLStatementGuard.classify(sql)
        #expect(c.kind == .dataModification)
        #expect(c.keyword == "UPDATE")
    }

    // MARK: - Unrecognized statements: never auto-approved

    @Test("Une instruction non reconnue n'est jamais silencieusement approuvée")
    func nonReconnu() {
        let c = SQLStatementGuard.classify("42 SELECT * FROM payees")
        #expect(c.kind == .unrecognized)
        #expect(c.kind.requiresDataModificationConfirmation)
        #expect(!c.kind.isBlockedBySchemaGuard)
    }

    @Test("Texte vide est unrecognized, pas query")
    func texteVide() {
        #expect(SQLStatementGuard.classify("").kind == .unrecognized)
        #expect(SQLStatementGuard.classify("   \n  ").kind == .unrecognized)
    }

    // MARK: - Batch evaluation

    @Test("Un lot avec au moins un DDL est bloqué dans son ensemble")
    func lotBloqueSiUnSeulDDL() {
        let assessment = SQLStatementGuard.assess([
            "SELECT * FROM payees",
            "DROP TABLE categories",
            "UPDATE payees SET name = 'x'"
        ])
        #expect(assessment.isBlocked)
        #expect(assessment.blockedStatements.count == 1)
        // A blocked batch doesn't need separate confirmation for the UPDATE:
        // nothing runs anyway.
        #expect(!assessment.needsConfirmation)
    }

    @Test("Un lot sans DDL mais avec du DML demande confirmation pour tout le lot")
    func lotConfirmationSiDML() {
        let assessment = SQLStatementGuard.assess([
            "SELECT * FROM payees",
            "UPDATE payees SET name = 'x' WHERE id = 1",
            "DELETE FROM tags WHERE id = 2"
        ])
        #expect(!assessment.isBlocked)
        #expect(assessment.needsConfirmation)
        #expect(assessment.statementsNeedingConfirmation.count == 2)
    }

    @Test("Un lot 100% lecture n'a besoin ni de blocage ni de confirmation")
    func lotLectureSeule() {
        let assessment = SQLStatementGuard.assess([
            "SELECT * FROM payees",
            "SELECT COUNT(*) FROM transactions",
            "PRAGMA table_info(categories)"
        ])
        #expect(!assessment.isBlocked)
        #expect(!assessment.needsConfirmation)
    }

    // MARK: - Shared messages (SQL Console + AI assistant)

    @Test("Le message de blocage cite le mot-clé et la cible")
    func messageBloque() {
        let c = SQLStatementGuard.classify("DROP TABLE payees")
        let message = SQLGuardMessages.blocked([c])
        #expect(message.contains("DROP"))
        #expect(message.contains("payees"))
    }

    @Test("Le message de confirmation regroupe par mot-clé et cible")
    func messageConfirmation() {
        let classifications = SQLStatementGuard.classify([
            "UPDATE payees SET name = 'x' WHERE id = 1",
            "UPDATE payees SET name = 'y' WHERE id = 2",
            "DELETE FROM tags WHERE id = 3"
        ])
        let message = SQLGuardMessages.confirmation(classifications)
        // "payees" must appear only once for the two (grouped) UPDATE statements.
        #expect(message.contains("UPDATE sur payees"))
        #expect(message.contains("DELETE sur tags"))
    }
}
