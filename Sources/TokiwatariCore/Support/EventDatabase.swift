import Foundation
import GRDB

/// SDK <-> CLI contract values for the events database.
enum DatabaseContract {
    /// The schema version this CLI understands (canon: skills/tokiwatari/references/schema.md).
    static let expectedUserVersion = 1

    static let fileName = "tokiwatari_debug_events.sqlite"
    /// Where the SDK creates the database inside the app's data container.
    static let containerRelativePath = "Library/Application Support/\(fileName)"

    static let columns = "session_id, session_sequence, timestamp, event_kind, identifier, http_method, url, status_code, duration_ms, payload_json"
}

struct OpenedDatabase {
    let queue: DatabaseQueue
    /// Non-null when the WAL-recovery fallback kicked in and we are reading a temp snapshot copy.
    let snapshotPath: String?
}

private func openReadonlyProbing(_ path: String) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: path, configuration: configuration)
    // Force a first read so WAL-recovery failures surface here, not later.
    _ = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
    return queue
}

/// Open the database read-only. If that fails (e.g. WAL recovery needed after
/// an app crash), copy db/-wal/-shm to a temp directory and open the snapshot.
func openDatabase(_ dbPath: String) throws -> OpenedDatabase {
    guard FileManager.default.fileExists(atPath: dbPath) else {
        throw CliError(
            "database not found: \(dbPath)",
            "Launch the app (DEBUG build with the Tokiwatari SDK) so it creates \(DatabaseContract.fileName), or check --db / --bundle-id / --udid. `tokiwatari doctor` shows how the path was resolved."
        )
    }
    do {
        return OpenedDatabase(queue: try openReadonlyProbing(dbPath), snapshotPath: nil)
    } catch let primaryError {
        do {
            return try openSnapshotCopy(dbPath)
        } catch let fallbackError {
            throw CliError(
                "failed to open database \(dbPath): \(primaryError) (snapshot fallback also failed: \(fallbackError))",
                "The file may not be a SQLite database. Check the path, or re-run `tokiwatari doctor`."
            )
        }
    }
}

private func openSnapshotCopy(_ dbPath: String) throws -> OpenedDatabase {
    let fileManager = FileManager.default
    let tmpDir = fileManager.temporaryDirectory
        .appendingPathComponent("tokiwatari-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let copyPath = tmpDir.appendingPathComponent((dbPath as NSString).lastPathComponent).path
    for suffix in ["", "-wal", "-shm"] {
        let src = dbPath + suffix
        if fileManager.fileExists(atPath: src) {
            try fileManager.copyItem(atPath: src, toPath: copyPath + suffix)
        }
    }
    do {
        return OpenedDatabase(queue: try openReadonlyProbing(copyPath), snapshotPath: copyPath)
    } catch {
        // The copy may still need WAL recovery, which requires a writable connection.
        // Recover on the private copy, then reopen readonly.
        let recovery = try DatabaseQueue(path: copyPath)
        _ = try recovery.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        try recovery.close()
        return OpenedDatabase(queue: try openReadonlyProbing(copyPath), snapshotPath: copyPath)
    }
}

/// Compare PRAGMA user_version with the version this CLI expects; mismatch is a hard error.
func checkUserVersion(_ db: Database) throws {
    let actual = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    guard actual == DatabaseContract.expectedUserVersion else {
        throw CliError(
            "schema version mismatch: expected user_version=\(DatabaseContract.expectedUserVersion), found \(actual)",
            "This tokiwatari-cli build supports schema user_version=\(DatabaseContract.expectedUserVersion) (version history: references/schema.md in the tokiwatari skill). The database was written with user_version=\(actual) — update tokiwatari-cli or the app-side SDK so both agree."
        )
    }
}

func withDatabase<T>(_ dbPath: String, _ fn: (Database) throws -> T) throws -> T {
    let opened = try openDatabase(dbPath)
    defer { try? opened.queue.close() }
    return try opened.queue.read { db in
        try checkUserVersion(db)
        return try fn(db)
    }
}

/// The latest session is the session_id owning MAX(timestamp).
func latestSessionId(_ db: Database) throws -> String {
    guard let sessionId = try String.fetchOne(
        db,
        sql: "SELECT session_id FROM events ORDER BY timestamp DESC, session_sequence DESC LIMIT 1"
    ) else {
        throw CliError(
            "no events found in the database",
            "Interact with the app first so events are recorded, or check that you are pointing at the right database (`tokiwatari doctor`)."
        )
    }
    return sessionId
}

struct EventRow {
    let sessionId: String
    let sessionSequence: Int64
    let timestamp: String
    let eventKind: String
    let identifier: String?
    let httpMethod: String?
    let url: String?
    let statusCode: Int64?
    let durationMs: Int64?
    let payloadJson: String?

    init(row: Row) {
        sessionId = row["session_id"]
        sessionSequence = row["session_sequence"]
        timestamp = row["timestamp"]
        eventKind = row["event_kind"]
        identifier = row["identifier"]
        httpMethod = row["http_method"]
        url = row["url"]
        statusCode = row["status_code"]
        durationMs = row["duration_ms"]
        payloadJson = row["payload_json"]
    }

    var jsonObject: [String: Any] {
        [
            "session_id": sessionId,
            "session_sequence": sessionSequence,
            "timestamp": timestamp,
            "event_kind": eventKind,
            "identifier": identifier ?? NSNull(),
            "http_method": httpMethod ?? NSNull(),
            "url": url ?? NSNull(),
            "status_code": statusCode ?? NSNull(),
            "duration_ms": durationMs ?? NSNull(),
            "payload_json": payloadJson ?? NSNull(),
        ]
    }

    var parsedPayload: [String: Any]? {
        guard let payloadJson,
              let parsed = try? JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) as? [String: Any]
        else { return nil }
        return parsed
    }
}

/// Fetch the newest `limit` rows matching where/params, returned in ascending session_sequence.
func latestRowsAscending(
    _ db: Database,
    where whereClause: String,
    params: [DatabaseValueConvertible?],
    limit: Int
) throws -> [EventRow] {
    let rows = try Row.fetchAll(
        db,
        sql: "SELECT \(DatabaseContract.columns) FROM events WHERE \(whereClause) ORDER BY session_sequence DESC LIMIT ?",
        arguments: StatementArguments(params + [limit])
    )
    return rows.reversed().map(EventRow.init)
}

struct SessionStats {
    let sessionId: String
    let eventCount: Int64
    let startedAt: String
    let endedAt: String
}

func sessionStats(_ db: Database, sessionId: String) throws -> SessionStats {
    guard let row = try Row.fetchOne(
        db,
        sql: "SELECT session_id, COUNT(*) AS event_count, MIN(timestamp) AS started_at, MAX(timestamp) AS ended_at FROM events WHERE session_id = ? GROUP BY session_id",
        arguments: [sessionId]
    ) else {
        throw CliError(
            "session not found: \(sessionId)",
            "Run `tokiwatari sessions` to list available session ids (newest first)."
        )
    }
    return SessionStats(
        sessionId: row["session_id"],
        eventCount: row["event_count"],
        startedAt: row["started_at"],
        endedAt: row["ended_at"]
    )
}

/// Resolve --session, defaulting to the latest session.
func resolveSession(_ db: Database, explicit: String?) throws -> String {
    if let explicit {
        _ = try sessionStats(db, sessionId: explicit) // validates existence
        return explicit
    }
    return try latestSessionId(db)
}

/// Convert a GRDB value to a JSON-safe value (for `query --json` output).
func jsonValue(_ dbValue: DatabaseValue) -> Any {
    switch dbValue.storage {
    case .null: return NSNull()
    case .int64(let value): return value
    case .double(let value): return value
    case .string(let value): return value
    case .blob(let data): return data.base64EncodedString()
    }
}
