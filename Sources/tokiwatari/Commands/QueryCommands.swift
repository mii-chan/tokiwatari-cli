import ArgumentParser
import Foundation
import GRDB

/// Runs command work with the error contract: CliError -> {error, hint} + exit 1.
func runReporting(_ global: GlobalOptions, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let exit as ExitCode {
        throw exit
    } catch {
        printFailure(json: global.json, error: error)
        throw ExitCode(1)
    }
}

struct SessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "list sessions (newest first) with start/end time and event count"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "max sessions to list") var limit: Int = 10

    func run() throws {
        try runReporting(global) {
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT session_id, COUNT(*) AS event_count, MIN(timestamp) AS started_at, MAX(timestamp) AS ended_at FROM events GROUP BY session_id ORDER BY ended_at DESC LIMIT ?",
                    arguments: [limit]
                )
                if rows.isEmpty {
                    throw CliError(
                        "no events found in the database",
                        "Interact with the app first so events are recorded, or check the database path with `tokiwatari doctor`."
                    )
                }
                let stats = rows.map { row in
                    SessionStats(
                        sessionId: row["session_id"], eventCount: row["event_count"],
                        startedAt: row["started_at"], endedAt: row["ended_at"]
                    )
                }
                let data = stats.map { s -> [String: Any] in
                    ["session_id": s.sessionId, "event_count": s.eventCount, "started_at": s.startedAt, "ended_at": s.endedAt]
                }
                printSuccess(json: global.json, data: data) {
                    stats.map {
                        renderSessionHeader(sessionId: $0.sessionId, count: $0.eventCount, start: $0.startedAt, end: $0.endedAt)
                    }.joined(separator: "\n")
                }
            }
        }
    }
}

struct TimelineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timeline",
        abstract: "merged UI+API timeline of a session (latest session when --session is omitted)"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "session id (default: latest session)") var session: String?
    @Option(help: "filter by event kind: api | ui") var kind: String?
    @Option(help: "max events to return") var limit: Int = 100
    @Option(help: "only events with session_sequence < n (cursor paging)") var beforeSeq: Int?

    func run() throws {
        try runReporting(global) {
            if let kind, kind != "api", kind != "ui" {
                throw CliError("invalid --kind: \(kind)", "Use --kind api or --kind ui.")
            }
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let sessionId = try resolveSession(db, explicit: session)
                let stats = try sessionStats(db, sessionId: sessionId)

                var whereClause = "session_id = ?"
                var params: [DatabaseValueConvertible?] = [sessionId]
                if let kind {
                    whereClause += " AND event_kind = ?"
                    params.append(kind)
                }
                if let beforeSeq {
                    whereClause += " AND session_sequence < ?"
                    params.append(beforeSeq)
                }
                let events = try latestRowsAscending(db, where: whereClause, params: params, limit: limit)

                let data: [String: Any] = [
                    "session_id": sessionId,
                    "event_count": stats.eventCount,
                    "started_at": stats.startedAt,
                    "ended_at": stats.endedAt,
                    "events": events.map(\.jsonObject),
                ]
                printSuccess(json: global.json, data: data) {
                    [
                        renderSessionHeader(sessionId: sessionId, count: stats.eventCount, start: stats.startedAt, end: stats.endedAt),
                        renderEventLines(events),
                    ].joined(separator: "\n")
                }
            }
        }
    }
}

struct AroundCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "around",
        abstract: "events around a given session_sequence (count limits and/or time window; the narrower wins)"
    )
    @OptionGroup var global: GlobalOptions
    @Argument(help: "center session_sequence") var sequence: Int
    @Option(help: "session id (default: latest session)") var session: String?
    @Option(help: "max events before the center") var before: Int = 10
    @Option(help: "max events after the center") var after: Int = 10
    @Option(help: "time window before the center in milliseconds") var beforeMs: Int?
    @Option(help: "time window after the center in milliseconds") var afterMs: Int?

    func run() throws {
        try runReporting(global) {
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let sessionId = try resolveSession(db, explicit: session)
                guard let centerRow = try Row.fetchOne(
                    db,
                    sql: "SELECT \(DatabaseContract.columns) FROM events WHERE session_id = ? AND session_sequence = ?",
                    arguments: [sessionId, sequence]
                ) else {
                    throw CliError(
                        "event not found: sequence \(sequence) in session \(sessionId)",
                        "Run `tokiwatari timeline` (or `ui` / `api`) to find valid sequence numbers first."
                    )
                }
                let center = EventRow(row: centerRow)

                // Count limits (--before/--after) and time windows (--before-ms/--after-ms):
                // when combined, both conditions apply, i.e. the narrower one wins.
                let centerDate = GrdbTime.parseGrdbTimestamp(center.timestamp) ?? Date()

                var beforeWhere = "session_id = ? AND session_sequence < ?"
                var beforeParams: [DatabaseValueConvertible?] = [sessionId, sequence]
                if let beforeMs {
                    beforeWhere += " AND timestamp >= ?"
                    beforeParams.append(GrdbTime.formatGrdbTimestamp(centerDate.addingTimeInterval(-Double(beforeMs) / 1000)))
                }
                let beforeRows = try Row.fetchAll(
                    db,
                    sql: "SELECT \(DatabaseContract.columns) FROM events WHERE \(beforeWhere) ORDER BY session_sequence DESC LIMIT ?",
                    arguments: StatementArguments(beforeParams + [before])
                ).reversed().map(EventRow.init)

                var afterWhere = "session_id = ? AND session_sequence > ?"
                var afterParams: [DatabaseValueConvertible?] = [sessionId, sequence]
                if let afterMs {
                    afterWhere += " AND timestamp <= ?"
                    afterParams.append(GrdbTime.formatGrdbTimestamp(centerDate.addingTimeInterval(Double(afterMs) / 1000)))
                }
                let afterRows = try Row.fetchAll(
                    db,
                    sql: "SELECT \(DatabaseContract.columns) FROM events WHERE \(afterWhere) ORDER BY session_sequence ASC LIMIT ?",
                    arguments: StatementArguments(afterParams + [after])
                ).map(EventRow.init)

                let events = beforeRows + [center] + afterRows // always ordered by session_sequence
                let data: [String: Any] = [
                    "session_id": sessionId,
                    "center_sequence": sequence,
                    "events": events.map(\.jsonObject),
                ]
                printSuccess(json: global.json, data: data) {
                    [
                        "session \(sessionId)  around seq \(sequence)  \(events.count) events",
                        renderEventLines(events),
                    ].joined(separator: "\n")
                }
            }
        }
    }
}

struct UiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "search UI events by identifier (SQL LIKE)"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "identifier LIKE pattern, e.g. 'tea_tapped_%'") var like: String?
    @Option(help: "session id (default: latest session)") var session: String?
    @Option(help: "max events to return") var limit: Int = 50

    func run() throws {
        try runReporting(global) {
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let sessionId = try resolveSession(db, explicit: session)
                var whereClause = "session_id = ? AND event_kind = 'ui'"
                var params: [DatabaseValueConvertible?] = [sessionId]
                if let like {
                    whereClause += " AND identifier LIKE ?"
                    params.append(like)
                }
                let events = try latestRowsAscending(db, where: whereClause, params: params, limit: limit)
                let data: [String: Any] = ["session_id": sessionId, "events": events.map(\.jsonObject)]
                printSuccess(json: global.json, data: data) {
                    let likeSuffix = like.map { "  like '\($0)'" } ?? ""
                    return [
                        "session \(sessionId)  \(events.count) ui events\(likeSuffix)",
                        renderEventLines(events),
                    ].joined(separator: "\n")
                }
            }
        }
    }
}

struct ApiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "search API logs by status, URL pattern, duration, and identifier (GraphQL operations)"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "exact status_code match") var status: Int?
    @Option(help: "url LIKE pattern, e.g. '%/v1/teas%'") var urlLike: String?
    @Option(help: "identifier LIKE pattern, e.g. 'GraphQL:Mutation:%' or '%:SearchTeas'") var like: String?
    @Option(help: "only requests taking at least n ms") var minDurationMs: Int?
    @Option(help: "session id (default: latest session)") var session: String?
    @Option(help: "max events to return") var limit: Int = 50

    func run() throws {
        try runReporting(global) {
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let sessionId = try resolveSession(db, explicit: session)
                var whereClause = "session_id = ? AND event_kind = 'api'"
                var params: [DatabaseValueConvertible?] = [sessionId]
                if let status {
                    whereClause += " AND status_code = ?"
                    params.append(status)
                }
                if let urlLike {
                    whereClause += " AND url LIKE ?"
                    params.append(urlLike)
                }
                if let like {
                    whereClause += " AND identifier LIKE ?"
                    params.append(like)
                }
                if let minDurationMs {
                    whereClause += " AND duration_ms >= ?"
                    params.append(minDurationMs)
                }
                let events = try latestRowsAscending(db, where: whereClause, params: params, limit: limit)
                let data: [String: Any] = ["session_id": sessionId, "events": events.map(\.jsonObject)]
                printSuccess(json: global.json, data: data) {
                    let likeSuffix = like.map { "  like '\($0)'" } ?? ""
                    return [
                        "session \(sessionId)  \(events.count) api events\(likeSuffix)",
                        renderEventLines(events),
                    ].joined(separator: "\n")
                }
            }
        }
    }
}

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "full detail of one event (headers/bodies/parameters). With a sequence: that event; without: the latest event matching the filters"
    )
    @OptionGroup var global: GlobalOptions
    @Argument(help: "session_sequence of the event (filters are ignored when given)") var sequence: Int?
    @Option(help: "session id (default: latest session)") var session: String?
    @Option(help: "filter: api | ui") var kind: String?
    @Option(help: "filter: exact status_code") var status: Int?
    @Option(help: "filter: url LIKE pattern, e.g. '%/v1/brews%'") var urlLike: String?
    @Option(help: "filter: identifier LIKE pattern, e.g. 'tea_tapped_%'") var like: String?

    func run() throws {
        try runReporting(global) {
            if let kind, kind != "api", kind != "ui" {
                throw CliError("invalid --kind: \(kind)", "Use --kind api or --kind ui.")
            }
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let sessionId = try resolveSession(db, explicit: session)

                let row: Row
                if let sequence {
                    guard let found = try Row.fetchOne(
                        db,
                        sql: "SELECT \(DatabaseContract.columns) FROM events WHERE session_id = ? AND session_sequence = ?",
                        arguments: [sessionId, sequence]
                    ) else {
                        throw CliError(
                            "event not found: sequence \(sequence) in session \(sessionId)",
                            "Run `tokiwatari timeline` (or `ui` / `api`) to find valid sequence numbers first."
                        )
                    }
                    row = found
                } else {
                    var whereClause = "session_id = ?"
                    var params: [DatabaseValueConvertible?] = [sessionId]
                    if let kind {
                        whereClause += " AND event_kind = ?"
                        params.append(kind)
                    }
                    if let status {
                        whereClause += " AND status_code = ?"
                        params.append(status)
                    }
                    if let urlLike {
                        whereClause += " AND url LIKE ?"
                        params.append(urlLike)
                    }
                    if let like {
                        whereClause += " AND identifier LIKE ?"
                        params.append(like)
                    }
                    guard let found = try Row.fetchOne(
                        db,
                        sql: "SELECT \(DatabaseContract.columns) FROM events WHERE \(whereClause) ORDER BY session_sequence DESC LIMIT 1",
                        arguments: StatementArguments(params)
                    ) else {
                        throw CliError(
                            "no matching event",
                            "Relax the filters, or run `tokiwatari timeline` to see what was recorded."
                        )
                    }
                    row = found
                }

                let event = EventRow(row: row)
                let payload = event.parsedPayload
                var data = event.jsonObject
                data["payload"] = payload ?? NSNull()
                printSuccess(json: global.json, data: data) {
                    renderEventDetail(event, payload: payload)
                }
            }
        }
    }
}

struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "run a read-only SQL query against the events database (the connection is readonly)"
    )
    @OptionGroup var global: GlobalOptions
    @Argument(help: "SQL SELECT statement") var sql: String

    func run() throws {
        try runReporting(global) {
            let dbPath = try resolveDbPath(global)
            try withDatabase(dbPath) { db in
                let statement: Statement
                do {
                    statement = try db.makeStatement(sql: sql)
                } catch {
                    throw CliError(
                        "SQL error: \(error)",
                        "Check the SQL against the events schema (see the tokiwatari skill references/schema.md, or `tokiwatari query \"SELECT sql FROM sqlite_master\"`)."
                    )
                }
                guard statement.columnCount > 0 else {
                    // The connection is readonly, so writes are structurally impossible anyway;
                    // fail with a clear message instead of a low-level SQLITE_READONLY error.
                    throw CliError(
                        "only read queries are supported: the connection is opened readonly",
                        "Use a SELECT statement. The Tokiwatari SDK is the sole writer of this database."
                    )
                }
                let rows = try Row.fetchAll(statement)
                let data = rows.map { row -> [String: Any] in
                    var object: [String: Any] = [:]
                    for (column, dbValue) in row {
                        object[column] = jsonValue(dbValue)
                    }
                    return object
                }
                printSuccess(json: global.json, data: data) {
                    if rows.isEmpty { return "(no rows)" }
                    let columns = Array(rows[0].columnNames)
                    var lines = [columns.joined(separator: "\t")]
                    for row in rows {
                        lines.append(columns.map { formatCell(row[$0] as DatabaseValue? ?? .null) }.joined(separator: "\t"))
                    }
                    return lines.joined(separator: "\n")
                }
            }
        }
    }
}

private func formatCell(_ dbValue: DatabaseValue) -> String {
    switch dbValue.storage {
    case .null: return ""
    case .blob(let data): return "<blob \(data.count)B>"
    case .int64(let value): return String(value)
    case .double(let value):
        if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    case .string(let value): return value
    }
}
