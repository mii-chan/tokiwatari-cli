import Foundation
import GRDB
import Testing

/// install-skill's copy source for tests (the products-dir binary has no sibling skills/).
let repoSkillsPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Tests/TokiwatariTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("skills/tokiwatari").path

let S1 = "AAAAAAAA-0000-0000-0000-000000000001"
let S2 = "AAAAAAAA-0000-0000-0000-000000000002"
let S3 = "AAAAAAAA-0000-0000-0000-000000000003"

// ---------------------------------------------------------------------------
// Binary under test
// ---------------------------------------------------------------------------

private final class BundleFinder {}

enum TestBinary {
    /// The suite is the CLI's behavior spec: it spawns the binary as a
    /// subprocess. TOKIWATARI_TEST_BIN overrides the binary under test
    /// (default: the `tokiwatari` executable in the build products directory,
    /// which `swift test` builds alongside the test bundle).
    static let url: URL = {
        if let override = ProcessInfo.processInfo.environment["TOKIWATARI_TEST_BIN"] {
            return URL(fileURLWithPath: override)
        }
        // <products dir>/<pkg>PackageTests.xctest/Contents/MacOS/... -> <products dir>/tokiwatari
        var directory = Bundle(for: BundleFinder.self).bundleURL
        while directory.path != "/", directory.pathExtension == "xctest" || directory.lastPathComponent == "Contents" || directory.lastPathComponent == "MacOS" {
            directory.deleteLastPathComponent()
        }
        let candidate = directory.appendingPathComponent("tokiwatari")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            fatalError("tokiwatari binary not found at \(candidate.path); set TOKIWATARI_TEST_BIN")
        }
        return candidate
    }()
}

struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Text output shows timestamps in the process's local timezone; pin the CLI
/// to UTC by default so fixture-based assertions are machine-independent.
@discardableResult
func run(_ arguments: [String], environment overrides: [String: String] = [:], currentDirectory: String? = nil) throws -> CLIResult {
    let process = Process()
    process.executableURL = TestBinary.url
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TZ"] = "UTC"
    for (key, value) in overrides {
        environment[key] = value
    }
    process.environment = environment
    if let currentDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIResult(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

@discardableResult
func runOk(_ arguments: [String], environment: [String: String] = [:]) throws -> CLIResult {
    let result = try run(arguments + ["--db", Fixture.shared.db], environment: environment)
    #expect(result.status == 0, "expected exit 0, got \(result.status)\nstdout: \(result.stdout)\nstderr: \(result.stderr)")
    return result
}

func runJSON(_ arguments: [String]) throws -> Any {
    let result = try runOk(arguments + ["--json"])
    return try JSONSerialization.jsonObject(with: Data(result.stdout.utf8), options: [.fragmentsAllowed])
}

func parseJSON(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

func lines(_ output: String) -> [String] {
    output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
}

// Loosely-typed accessors for JSON assertions.
func asDict(_ value: Any?) throws -> [String: Any] {
    try #require(value as? [String: Any])
}

func asArray(_ value: Any?) throws -> [Any] {
    try #require(value as? [Any])
}

func asInt(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

// ---------------------------------------------------------------------------
// Fixtures (written once per test run into a temp directory)
// ---------------------------------------------------------------------------

enum Fixture {
    static let shared: (db: String, mismatch: String) = {
        do {
            return try FixtureFactory.writeAll()
        } catch {
            fatalError("failed to write fixtures: \(error)")
        }
    }()
}

/// GRDB-compatible fixture databases:
/// - tokiwatari_debug_events.sqlite : user_version=1, 3 sessions, 43 mixed ui/api events
/// - mismatch.sqlite     : user_version=2 (schema drift case)
enum FixtureFactory {

    struct Event {
        var kind: String
        var identifier: String?
        var method: String?
        var url: String?
        var status: Int?
        var duration: Int?
        var payload: String?
    }

    static func ui(_ identifier: String, _ paramsJson: String? = nil) -> Event {
        // The SDK serializes event.parameters as-is; empty parameters become NULL.
        Event(kind: "ui", identifier: identifier, payload: paramsJson)
    }

    // payload_json in the same shape as the SDK: nested JSON bodies,
    // app-supplied identifier, and independently present request/response/error components.
    static func api(
        _ method: String,
        _ urlPath: String,
        _ status: Int?,
        _ durationMs: Int,
        requestBody: Any? = nil,
        responseBody: Any? = nil,
        error: [String: Any]? = nil,
        identifier: String? = nil,
        payloadOverride: [String: Any]? = nil
    ) -> Event {
        let payloadObject: [String: Any]
        if let payloadOverride {
            payloadObject = payloadOverride
        } else {
            var request: [String: Any] = [
                "headers": ["Accept": "application/json", "Authorization": "<redacted>"],
            ]
            if let requestBody { request["body"] = requestBody }
            var components: [String: Any] = ["request": request]
            if status != nil {
                var response: [String: Any] = ["headers": ["Content-Type": "application/json"]]
                if let responseBody { response["body"] = responseBody }
                components["response"] = response
            }
            if let error { components["error"] = error }
            payloadObject = components
        }
        let payload = try! JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        return Event(
            kind: "api",
            identifier: identifier,
            method: method,
            url: "https://api.example.com\(urlPath)",
            status: status,
            duration: durationMs,
            payload: String(decoding: payload, as: UTF8.self)
        )
    }

    /// A stored GraphQL request body: the query document is never stored.
    static func graphQLRequestBody(variables: [String: Any], operationName: String) -> [String: Any] {
        ["query": "<omitted>", "variables": variables, "operationName": operationName]
    }

    /// GRDB stores Date as "yyyy-MM-dd HH:mm:ss.SSS" in UTC.
    static func grdbTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    static func baseDate() -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: "2026-07-05 09:00:00")! // 09:00 UTC
    }

    static let SCHEMA = """
        CREATE TABLE events (
          session_id        TEXT    NOT NULL,
          session_sequence  INTEGER NOT NULL,
          timestamp         TEXT    NOT NULL,
          event_kind        TEXT    NOT NULL,
          identifier        TEXT,
          http_method       TEXT,
          url               TEXT,
          status_code       INTEGER,
          duration_ms       INTEGER,
          payload_json      TEXT,
          PRIMARY KEY (session_id, session_sequence)
        );
        CREATE INDEX idx_events_identifier ON events(identifier);
        CREATE INDEX idx_events_kind       ON events(event_kind, session_id);
        CREATE INDEX idx_events_time       ON events(session_id, timestamp);
        """

    static func writeAll() throws -> (db: String, mismatch: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("tokiwatari_debug_events.sqlite").path
        let mismatchPath = directory.appendingPathComponent("mismatch.sqlite").path

        let base = baseDate()
        try write(
            to: dbPath,
            userVersion: 1,
            sessions: [
                (id: S1, base: base, events: session1Events()),
                (id: S2, base: base.addingTimeInterval(30 * 60), events: session2Events()),
                (id: S3, base: base.addingTimeInterval(60 * 60), events: session3Events()),
            ]
        )
        try write(
            to: mismatchPath,
            userVersion: 2,
            sessions: [(id: S1, base: base, events: [ui("screen_viewed_home")])]
        )
        return (dbPath, mismatchPath)
    }

    private static func write(
        to path: String,
        userVersion: Int,
        sessions: [(id: String, base: Date, events: [Event])]
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: SCHEMA)
            for session in sessions {
                for (index, event) in session.events.enumerated() {
                    let sequence = index + 1
                    try db.execute(
                        sql: """
                        INSERT INTO events (session_id, session_sequence, timestamp, event_kind, identifier,
                                            http_method, url, status_code, duration_ms, payload_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            session.id,
                            sequence,
                            grdbTimestamp(session.base.addingTimeInterval(Double(sequence) * 0.25)),
                            event.kind,
                            event.identifier,
                            event.method,
                            event.url,
                            event.status,
                            event.duration,
                            event.payload,
                        ]
                    )
                }
            }
            try db.execute(sql: "PRAGMA user_version = \(userVersion)")
        }
        try queue.close()
    }

    // --- session 1: 8 events (oldest) ---------------------------------------
    private static func session1Events() -> [Event] {
        [
            ui("screen_viewed_home"),
            api("GET", "/v1/teas", 200, 120, identifier: "GET /v1/teas"),
            ui("tea_tapped_10", #"{"tea_id":10}"#),
            api("GET", "/v1/teas/10", 200, 95, identifier: "GET /v1/teas/10"),
            ui("tea_tapped_11", #"{"tea_id":11}"#),
            api("GET", "/v1/teas/11", 200, 101, identifier: "GET /v1/teas/11"),
            ui("screen_viewed_settings"),
            ui("toggle_switched_notifications", #"{"enabled":true}"#),
        ]
    }

    // --- session 2: 15 events (mixed REST + GraphQL session) ----------------
    private static func session2Events() -> [Event] {
        var events: [Event] = [ui("screen_viewed_home"), api("GET", "/v1/teas", 200, 142)]
        for i in 1...5 {
            events.append(ui("tea_tapped_\(20 + i)", #"{"tea_id":\#(20 + i)}"#))
            events.append(api("GET", "/v1/teas/\(20 + i)", 200, 80 + i))
        }
        events.append(ui("screen_viewed_search"))
        events.append(api(
            "POST", "/graphql", 200, 145,
            requestBody: graphQLRequestBody(variables: ["keyword": "hojicha"], operationName: "SearchTeas"),
            responseBody: ["data": ["search": [["id": 21, "name": "Hojicha"]]]],
            identifier: "SearchTeas"
        ))
        events.append(api(
            "POST", "/graphql", 200, 210,
            requestBody: graphQLRequestBody(variables: ["teaId": 21], operationName: "AddFavorite"),
            responseBody: ["data": ["addFavorite": ["ok": true]]],
            identifier: "AddFavorite"
        ))
        return events
    }

    // --- session 3: 20 events (latest; contains the failing brew flow) -------
    private static func session3Events() -> [Event] {
        [
            ui("screen_viewed_home"),
            api("GET", "/v1/teas", 200, 152,
                responseBody: ["body_unavailable": "sanitized_body_too_large", "original_bytes": 87543]),
            ui("tea_tapped_1", #"{"tea_id":1}"#),
            api("GET", "/v1/teas/1", 200, 98),
            ui("tea_tapped_2", #"{"tea_id":2}"#),
            api("GET", "/v1/teas/2", 404, 87, responseBody: ["error": "not_found"]),
            ui("screen_viewed_brew"),
            api("POST", "/v1/brews", 500, 1240,
                requestBody: ["tea_id": 2, "steep_seconds": 90],
                responseBody: ["error": "timer_backend_timeout"]),
            ui("alert_shown_brew_error"),
            ui("tea_tapped_3", #"{"tea_id":3}"#),
            api("GET", "/v1/teas/3", 200, 110, responseBody: NSNull()),
            ui("tea_tapped_4", #"{"tea_id":4}"#),
            api("GET", "/v1/teas/4", 200, 104, payloadOverride: [
                "payload_dropped": "event_too_large",
                "original_bytes": 300_000,
            ]),
            ui("screen_viewed_brew"),
            api("POST", "/v1/brews", 201, 320, requestBody: ["steep_seconds": 60, "tea_id": 3]),
            ui("screen_viewed_tasting"),
            api("POST", "/v1/tasting_notes", nil, 640, error: ["domain": "NSURLErrorDomain", "code": -1001]),
            ui("screen_viewed_brew_complete"),
            ui("button_tapped_back_to_home"),
            ui("screen_viewed_home"),
        ]
    }
}
