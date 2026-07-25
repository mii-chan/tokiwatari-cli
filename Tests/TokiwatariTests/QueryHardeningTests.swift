import Foundation
import GRDB
import SQLite3
import Testing
@testable import TokiwatariCore

@Suite struct QueryHardeningTests {

    @Test func deleteReturningIsRejectedByTheReadonlyGuard() throws {
        let result = try run(["query", "DELETE FROM events RETURNING session_id", "--db", Fixture.shared.db])
        #expect(result.status == 1)
        #expect(result.stderr.contains("only read queries are supported"))
    }

    @Test func connectionForbidsAttachedDatabases() throws {
        let opened = try openDatabase(Fixture.shared.db)
        defer { opened.closeAndCleanup() }
        try opened.queue.read { db in
            // Passing a negative value returns the current limit without changing it.
            #expect(sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_ATTACHED, -1) == 0)
            #expect(throws: DatabaseError.self) {
                try Row.fetchAll(db, sql: "ATTACH DATABASE ':memory:' AS x")
            }
        }
    }

    @Test func connectionCapsSingleValueLength() throws {
        let opened = try openDatabase(Fixture.shared.db)
        defer { opened.closeAndCleanup() }
        try opened.queue.read { db in
            #expect(sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_LENGTH, -1) == QueryResourceLimits.sqliteLengthBytes)
        }
    }

    @Test func valueAtExactlyTheLengthLimitSucceeds() throws {
        let result = try runOk(["query", "SELECT zeroblob(\(QueryResourceLimits.sqliteLengthBytes)) AS b"])
        #expect(result.stdout.contains("<blob \(QueryResourceLimits.sqliteLengthBytes)B>"))
    }

    @Test func valueOverTheLengthLimitFailsWithHint() throws {
        let result = try run(
            ["query", "SELECT zeroblob(\(Int(QueryResourceLimits.sqliteLengthBytes) + 1)) AS b", "--db", Fixture.shared.db]
        )
        #expect(result.status == 1)
        #expect(result.stderr.contains("exceeds the \(QueryResourceLimits.sqliteLengthBytes / (1024 * 1024)) MiB single-value limit"))
        #expect(result.stderr.contains("hint:"))
        #expect(result.stderr.contains("cannot be materialized"))
    }

    @Test func partialReadsOfOversizedValuesFailTheSameWay() throws {
        let result = try run(
            ["query", "SELECT substr(zeroblob(\(Int(QueryResourceLimits.sqliteLengthBytes) + 1)), 1, 1) AS b", "--db", Fixture.shared.db]
        )
        #expect(result.status == 1)
        #expect(result.stderr.contains("single-value limit"))
    }
}
