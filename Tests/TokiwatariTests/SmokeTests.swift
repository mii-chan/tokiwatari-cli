import Foundation
import Testing

// The CLI's behavior spec: every test spawns the built binary as a subprocess
// and asserts on stdout/stderr/exit code — implementation-agnostic by construction.

// MARK: - sessions

@Suite struct SessionsTests {
    @Test func textListsThreeSessionsNewestFirst() throws {
        let output = lines(try runOk(["sessions"]).stdout)
        #expect(output.count == 3)
        #expect(output[0] == "session \(S3)  20 events  2026-07-05 10:00:00 ~ 10:00:05")
        #expect(output[2].contains(S1))
        #expect(output[2].contains("8 events"))
    }

    @Test func jsonListsSessionsOrderedByLastActivity() throws {
        let data = try asArray(try runJSON(["sessions"]))
        #expect(data.count == 3)
        let first = try asDict(data[0])
        let last = try asDict(data[2])
        #expect(first["session_id"] as? String == S3)
        #expect(asInt(first["event_count"]) == 20)
        #expect(last["session_id"] as? String == S1)
        #expect(first["started_at"] as? String == "2026-07-05 10:00:00.250")
    }

    @Test func limitReturnsOnlyTheLatestSession() throws {
        let data = try asArray(try runJSON(["sessions", "--limit", "1"]))
        #expect(data.count == 1)
        #expect(try asDict(data[0])["session_id"] as? String == S3)
    }
}

// MARK: - timeline

@Suite struct TimelineTests {
    @Test func textDefaultsToLatestSessionWithCompactRows() throws {
        let output = lines(try runOk(["timeline"]).stdout)
        #expect(output[0] == "session \(S3)  20 events  2026-07-05 10:00:00 ~ 10:00:05")
        #expect(output[1].firstMatch(of: /^seq\s+time\s+kind\s+summary$/) != nil)
        #expect(output.count == 2 + 20)
        // API summary format: "METHOD path status durationms"
        let brewLine = try #require(output.first { $0.contains("/v1/brews 500") })
        #expect(brewLine.firstMatch(of: /^8\s+10:00:02\.000\s+api\s+POST \/v1\/brews 500 1240ms$/) != nil)
        // UI summary is the identifier
        let uiLine = try #require(output.first { $0.hasPrefix("9 ") })
        #expect(uiLine.firstMatch(of: /ui\s+alert_shown_brew_error$/) != nil)
    }

    @Test func jsonKindApiFiltersAndKeepsSequenceOrder() throws {
        let data = try asDict(try runJSON(["timeline", "--kind", "api"]))
        #expect(data["session_id"] as? String == S3)
        #expect(asInt(data["event_count"]) == 20) // session total, not filtered count
        let events = try asArray(data["events"]).map { try asDict($0) }
        #expect(events.allSatisfy { $0["event_kind"] as? String == "api" })
        let seqs = events.compactMap { asInt($0["session_sequence"]) }
        #expect(seqs == seqs.sorted())
    }

    @Test func sessionLimitAndBeforeSeqCursorPaging() throws {
        let data = try asDict(try runJSON(["timeline", "--session", S1, "--limit", "3", "--before-seq", "7"]))
        #expect(data["session_id"] as? String == S1)
        let seqs = try asArray(data["events"]).map { asInt(try asDict($0)["session_sequence"]) }
        #expect(seqs == [4, 5, 6])
    }

    @Test func textOutputIsLocalTimeAndJSONKeepsStoredUTC() throws {
        // fixture S1 runs 2026-07-05 09:00:00.250 ~ 09:00:02.000 UTC = 18:00 JST
        let text = try run(
            ["timeline", "--session", S1, "--db", Fixture.shared.db],
            environment: ["TZ": "Asia/Tokyo"]
        )
        #expect(text.status == 0)
        #expect(text.stdout.contains("2026-07-05 18:00:00 ~ 18:00:02"))
        #expect(text.stdout.contains("18:00:00.250"))

        let show = try run(
            ["show", "1", "--session", S1, "--db", Fixture.shared.db],
            environment: ["TZ": "Asia/Tokyo"]
        )
        #expect(show.stdout.contains("time      2026-07-05 18:00:00.250 +09:00"))

        let json = try run(
            ["timeline", "--session", S1, "--db", Fixture.shared.db, "--json"],
            environment: ["TZ": "Asia/Tokyo"]
        )
        let data = try asDict(try parseJSON(json.stdout))
        #expect(data["started_at"] as? String == "2026-07-05 09:00:00.250") // stored value, untouched
        let firstEvent = try asDict(try asArray(data["events"])[0])
        #expect(firstEvent["timestamp"] as? String == "2026-07-05 09:00:00.250")
    }

    @Test func unknownSessionFailsWithHintPointingAtSessions() throws {
        let result = try run(["timeline", "--session", "nope", "--db", Fixture.shared.db, "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("session not found") == true)
        #expect((envelope["hint"] as? String)?.contains("tokiwatari sessions") == true)
    }
}

// MARK: - ui / api

@Suite struct UiApiTests {
    @Test func uiLikeTextShowsOnlyMatchingIdentifiers() throws {
        let output = lines(try runOk(["ui", "--like", "tea_tapped_%"]).stdout)
        #expect(output[0].firstMatch(of: /4 ui events {2}like 'tea_tapped_%'/) != nil)
        let rows = Array(output.dropFirst(2))
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.firstMatch(of: /ui\s+tea_tapped_\d+$/) != nil)
        }
    }

    @Test func uiLikeJSONReturnsUiEventsMatchingThePattern() throws {
        let data = try asDict(try runJSON(["ui", "--like", "tea_tapped_%"]))
        #expect(data["session_id"] as? String == S3)
        let events = try asArray(data["events"]).map { try asDict($0) }
        #expect(events.map { $0["identifier"] as? String } == ["tea_tapped_1", "tea_tapped_2", "tea_tapped_3", "tea_tapped_4"])
        #expect(events.allSatisfy { $0["event_kind"] as? String == "ui" })
    }

    @Test func apiStatus500ReturnsExactlyTheFailingBrewPost() throws {
        let data = try asDict(try runJSON(["api", "--status", "500"]))
        let events = try asArray(data["events"])
        #expect(events.count == 1)
        let event = try asDict(events[0])
        #expect(asInt(event["session_sequence"]) == 8)
        #expect(event["http_method"] as? String == "POST")
        #expect(event["url"] as? String == "https://api.example.com/v1/brews")
        #expect(asInt(event["duration_ms"]) == 1240)
    }

    @Test func apiMinDurationAndUrlLikeFilters() throws {
        let slow = try asDict(try runJSON(["api", "--min-duration-ms", "1000"]))
        let slowSeqs = try asArray(slow["events"]).map { asInt(try asDict($0)["session_sequence"]) }
        #expect(slowSeqs == [8])

        let teas = try asDict(try runJSON(["api", "--url-like", "%/v1/teas%"]))
        let teaEvents = try asArray(teas["events"]).map { try asDict($0) }
        #expect(teaEvents.count == 5)
        #expect(teaEvents.allSatisfy { ($0["url"] as? String)?.contains("/v1/teas") == true })
    }
}

// MARK: - GraphQL: identifier = "GraphQL:<Type>:<Name>"

@Suite struct GraphQLTests {
    @Test func apiLikeSearchesGraphQLOperationsByIdentifier() throws {
        let all = try asDict(try runJSON(["api", "--like", "GraphQL:%", "--session", S2]))
        let identifiers = try asArray(all["events"]).map { try asDict($0)["identifier"] as? String }
        #expect(identifiers == ["GraphQL:Query:SearchTeas", "GraphQL:Mutation:AddFavorite"])

        let mutations = try asDict(try runJSON(["api", "--like", "GraphQL:Mutation:%", "--session", S2]))
        let mutationIds = try asArray(mutations["events"]).map { try asDict($0)["identifier"] as? String }
        #expect(mutationIds == ["GraphQL:Mutation:AddFavorite"])

        let byName = try asDict(try runJSON(["api", "--like", "%:SearchTeas", "--session", S2]))
        let byNameEvents = try asArray(byName["events"])
        #expect(byNameEvents.count == 1)
        #expect(try asDict(byNameEvents[0])["url"] as? String == "https://api.example.com/graphql")
    }

    @Test func timelineShowsTheOperationInsteadOfThePath() throws {
        let result = try runOk(["timeline", "--session", S2])
        #expect(result.stdout.firstMatch(of: /api\s+POST GraphQL:Query:SearchTeas 200 145ms/) != nil)
        #expect(result.stdout.firstMatch(of: /api\s+POST GraphQL:Mutation:AddFavorite 200 210ms/) != nil)
        #expect(!result.stdout.contains("POST /graphql")) // the path is replaced when identifier exists
    }

    @Test func showRendersTheQueryUnfoldedPlusVariables() throws {
        let result = try runOk(["show", "--like", "GraphQL:Query:%", "--session", S2])
        #expect(result.stdout.contains("call      POST GraphQL:Query:SearchTeas 200 145ms"))
        #expect(result.stdout.contains("request body (GraphQL):"))
        // "\n" in the JSON string becomes real newlines
        #expect(result.stdout.firstMatch(of: /query SearchTeas\(\$keyword: String!\) \{\n\s+search\(keyword: \$keyword\)/) != nil)
        #expect(result.stdout.contains("variables:"))
        #expect(result.stdout.contains(#""keyword": "hojicha""#))
    }
}

// MARK: - around

@Suite struct AroundTests {
    @Test func countLimitsOrderedBySequenceIncludingCenter() throws {
        let data = try asDict(try runJSON(["around", "8", "--before", "2", "--after", "2"]))
        #expect(asInt(data["center_sequence"]) == 8)
        let seqs = try asArray(data["events"]).map { asInt(try asDict($0)["session_sequence"]) }
        #expect(seqs == [6, 7, 8, 9, 10])
    }

    @Test func combiningCountsAndTimeWindowAppliesTheNarrowerOne() throws {
        // events are 250ms apart; ±300ms window keeps only seq 7 and 9 around center 8
        let data = try asDict(try runJSON([
            "around", "8",
            "--before", "5", "--after", "5",
            "--before-ms", "300", "--after-ms", "300",
        ]))
        let seqs = try asArray(data["events"]).map { asInt(try asDict($0)["session_sequence"]) }
        #expect(seqs == [7, 8, 9])
    }

    @Test func textHeaderAndRowFormat() throws {
        let output = lines(try runOk(["around", "8", "--before", "1", "--after", "1"]).stdout)
        #expect(output[0] == "session \(S3)  around seq 8  3 events")
        #expect(output[3].firstMatch(of: /^8\s+10:00:02\.000\s+api\s+POST \/v1\/brews 500 1240ms$/) != nil)
    }

    @Test func missingSequenceFailsWithHint() throws {
        let result = try run(["around", "999", "--db", Fixture.shared.db, "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("event not found") == true)
        #expect((envelope["hint"] as? String)?.contains("timeline") == true)
    }
}

// MARK: - query

@Suite struct QueryTests {
    @Test func textIsTabSeparatedWithHeader() throws {
        let output = lines(try runOk(["query", "SELECT COUNT(*) AS n FROM events"]).stdout)
        #expect(output == ["n", "43"])
    }

    @Test func jsonReturnsRowsAsObjectsAndJsonExtractWorks() throws {
        let data = try asArray(try runJSON([
            "query",
            """
            SELECT identifier, json_extract(payload_json, '$.tea_id') AS tea_id
            FROM events WHERE event_kind='ui' AND identifier LIKE 'tea_tapped_%' AND session_id='\(S3)'
            ORDER BY session_sequence
            """,
        ]))
        #expect(data.count == 4)
        let first = try asDict(data[0])
        #expect(first["identifier"] as? String == "tea_tapped_1")
        #expect(asInt(first["tea_id"]) == 1)
    }

    @Test func writeStatementsAreRejected() throws {
        let result = try run(["query", "DELETE FROM events", "--db", Fixture.shared.db, "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.lowercased().contains("readonly") == true)
    }

    @Test func controlCharactersAreEscapedInTextOutput() throws {
        // Recorded content can carry terminal escape sequences (char(27) = ESC);
        // the text path must neutralize them instead of driving the terminal.
        let output = lines(try runOk(["query", "SELECT char(27) || '[31mred' AS v"]).stdout)
        #expect(output == ["v", #"\u001b[31mred"#])
    }
}

// MARK: - show

@Suite struct ShowTests {
    @Test func bySequenceJSONReturnsFullRowWithParsedPayload() throws {
        let data = try asDict(try runJSON(["show", "8"])) // POST /v1/brews 500 in the latest session
        #expect(data["session_id"] as? String == S3)
        #expect(asInt(data["session_sequence"]) == 8)
        #expect(asInt(data["status_code"]) == 500)
        let payload = try asDict(data["payload"])
        let request = try asDict(payload["request"])
        #expect(request["body"] as? String == #"{"tea_id":2,"steep_seconds":90}"#) // stored bytes, original key order
        #expect(try asDict(request["headers"])["Authorization"] as? String == "<redacted>")
        let response = try asDict(payload["response"])
        #expect((response["body"] as? String)?.contains("timer_backend_timeout") == true)
    }

    @Test func byStatusPicksTheLatestMatchAndRendersBodies() throws {
        let result = try runOk(["show", "--status", "500"])
        #expect(result.stdout.contains("kind      api"))
        #expect(result.stdout.contains("POST /v1/brews 500 1240ms"))
        #expect(result.stdout.contains("request body:"))
        // pretty-printed with keys sorted for display (stored value keeps quantity first)
        #expect(result.stdout.firstMatch(of: /"steep_seconds": 90,\n\s+"tea_id": 2/) != nil)
        #expect(result.stdout.contains("timer_backend_timeout"))
    }

    @Test func bodyTruncatedIsSurfaced() throws {
        let result = try runOk(["show", "2"]) // GET /v1/teas with response.body_truncated = true
        #expect(result.stdout.contains("response body (truncated at 64KB):"))
    }

    @Test func withoutArgumentsReturnsLatestMatchWithUiParameters() throws {
        let data = try asDict(try runJSON(["show", "--like", "tea_tapped_%"]))
        #expect(data["event_kind"] as? String == "ui")
        #expect(data["identifier"] as? String == "tea_tapped_4") // latest match in S3
        let payload = try asDict(data["payload"])
        #expect(asInt(payload["tea_id"]) == 4)
        #expect(payload.count == 1)
    }

    @Test func noMatchingEventFailsWithHint() throws {
        let result = try run(["show", "--status", "999", "--db", Fixture.shared.db, "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("no matching event") == true)
        #expect((envelope["hint"] as? String)?.contains("timeline") == true)
    }
}

// MARK: - doctor

@Suite struct DoctorTests {
    @Test func textReportsDbUserVersionAndCounts() throws {
        let result = try runOk(["doctor"])
        #expect(result.stdout.firstMatch(of: /user_version\s+expected 1, found 1/) != nil)
        #expect(result.stdout.contains("43 events in 3 sessions"))
        #expect(result.stdout.contains("all checks passed"))
        #expect(result.stdout.contains("skipped (--db specified)"))
    }

    @Test func jsonReturnsOkEnvelopeWithPerCheckResults() throws {
        let data = try asDict(try runJSON(["doctor"]))
        #expect(data["ok"] as? Bool == true)
        let checks = try asArray(data["checks"]).map { try asDict($0) }
        let names = checks.compactMap { $0["name"] as? String }
        for expected in ["xcrun", "config", "db path", "db file", "wal", "open readonly", "user_version", "events"] {
            #expect(names.contains(expected), "missing check: \(expected)")
        }
        #expect(checks.allSatisfy { $0["ok"] as? Bool == true })
    }
}

// MARK: - user_version mismatch

@Suite struct UserVersionMismatchTests {
    @Test func jsonReportsExpectedAndActualWithHint() throws {
        let result = try run(["sessions", "--db", Fixture.shared.mismatch, "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("expected user_version=1, found 2") == true)
        let hint = try #require(envelope["hint"] as? String)
        #expect(hint.contains("user_version=1"))
        #expect(hint.contains("user_version=2"))
    }

    @Test func textPutsErrorAndHintOnStderrWithExit1() throws {
        let result = try run(["timeline", "--db", Fixture.shared.mismatch])
        #expect(result.status == 1)
        #expect(result.stderr.contains("error: schema version mismatch"))
        #expect(result.stderr.contains("hint: "))
    }

    @Test func doctorFlagsTheMismatchButKeepsDiagnosing() throws {
        let result = try run(["doctor", "--db", Fixture.shared.mismatch, "--json"])
        #expect(result.status == 1)
        let data = try asDict(try parseJSON(result.stdout))
        #expect(data["ok"] as? Bool == false)
        let versionCheck = try #require(
            try asArray(data["checks"]).map { try asDict($0) }.first { $0["name"] as? String == "user_version" }
        )
        #expect(versionCheck["ok"] as? Bool == false)
        #expect((versionCheck["detail"] as? String)?.contains("expected 1, found 2") == true)
    }
}

// MARK: - install-skill

@Suite struct InstallSkillTests {
    private func temporaryDest() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-skill-\(UUID().uuidString)").path
    }

    @Test func installsSkillAndReferencesToDest() throws {
        let dest = temporaryDest()
        defer { try? FileManager.default.removeItem(atPath: dest) }

        let result = try run(
            ["install-skill", "--dest", dest, "--json"],
            environment: ["TOKIWATARI_SKILLS_PATH": repoSkillsPath]
        )
        #expect(result.status == 0)
        let data = try asDict(try parseJSON(result.stdout))
        #expect(data["dest"] as? String == dest)
        let files = try #require(data["files"] as? [String])
        for expected in ["SKILL.md", "references/schema.md"] {
            #expect(files.contains(expected), "missing \(expected) in reported files")
            #expect(FileManager.default.fileExists(atPath: (dest as NSString).appendingPathComponent(expected)), "missing \(expected) on disk")
        }
        let skill = try String(contentsOfFile: (dest as NSString).appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(skill.contains("sessions"))
        #expect(skill.contains("around"))
    }

    @Test func skillsPathFlagSelectsTheCopySource() throws {
        let dest = temporaryDest()
        defer { try? FileManager.default.removeItem(atPath: dest) }

        let result = try run(["install-skill", "--dest", dest, "--skills-path", repoSkillsPath, "--json"])
        #expect(result.status == 0)
        let data = try asDict(try parseJSON(result.stdout))
        #expect((data["files"] as? [String])?.contains("SKILL.md") == true)
    }

    private func makeSkillSource(_ marker: String) throws -> String {
        let dir = temporaryDest()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try marker.write(toFile: (dir as NSString).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func skillsPathFlagWinsOverEnvironment() throws {
        let flagSource = try makeSkillSource("from-flag")
        let envSource = try makeSkillSource("from-env")
        let dest = temporaryDest()
        defer {
            try? FileManager.default.removeItem(atPath: flagSource)
            try? FileManager.default.removeItem(atPath: envSource)
            try? FileManager.default.removeItem(atPath: dest)
        }

        let result = try run(
            ["install-skill", "--dest", dest, "--skills-path", flagSource, "--json"],
            environment: ["TOKIWATARI_SKILLS_PATH": envSource]
        )
        #expect(result.status == 0)
        let installed = try String(contentsOfFile: (dest as NSString).appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(installed == "from-flag")
    }

    @Test func invalidSkillsPathDoesNotFallBackToEnvironment() throws {
        let result = try run(
            ["install-skill", "--dest", temporaryDest(), "--skills-path", "/nonexistent/skills", "--json"],
            environment: ["TOKIWATARI_SKILLS_PATH": repoSkillsPath]
        )
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("no SKILL.md found at --skills-path") == true)
    }

    @Test func skipsHiddenFilesAndHiddenDirectoryContents() throws {
        let source = temporaryDest()
        let dest = temporaryDest()
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: dest)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: (source as NSString).appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "skill".write(toFile: (source as NSString).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "leak".write(toFile: (source as NSString).appendingPathComponent(".hidden/leak.md"), atomically: true, encoding: .utf8)
        try "junk".write(toFile: (source as NSString).appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let result = try run(["install-skill", "--dest", dest, "--skills-path", source, "--json"])
        #expect(result.status == 0)
        let data = try asDict(try parseJSON(result.stdout))
        #expect(data["files"] as? [String] == ["SKILL.md"])
        #expect(!fileManager.fileExists(atPath: (dest as NSString).appendingPathComponent(".hidden/leak.md")))
    }

    @Test func unwritableDestFailsWithHint() throws {
        let parent = temporaryDest()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
            try? FileManager.default.removeItem(atPath: parent)
        }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)

        let result = try run(
            ["install-skill", "--dest", (parent as NSString).appendingPathComponent("dest"), "--json"],
            environment: ["TOKIWATARI_SKILLS_PATH": repoSkillsPath]
        )
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("cannot copy") == true)
        #expect((envelope["hint"] as? String)?.contains("--dest") == true)
    }

    @Test func invalidSkillsPathFailsWithHint() throws {
        let result = try run(["install-skill", "--dest", temporaryDest(), "--skills-path", "/nonexistent/skills", "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("no SKILL.md found") == true)
        #expect((envelope["hint"] as? String)?.contains("--skills-path") == true)
    }

    @Test func failsWithHintWhenNoSkillSourceIsFound() throws {
        // Empty TOKIWATARI_SKILLS_PATH counts as unset; the products-dir binary has no discoverable skills/.
        let result = try run(
            ["install-skill", "--dest", temporaryDest(), "--json"],
            environment: ["TOKIWATARI_SKILLS_PATH": ""]
        )
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["hint"] as? String)?.contains("--skills-path") == true)
    }

    @Test func destIsRequired() throws {
        let result = try run(["install-skill"])
        #expect(result.status != 0)
        #expect(result.stderr.contains("--dest")) // usage error names the missing option
    }
}

// MARK: - resolution errors

@Suite struct ResolutionTests {
    @Test func invalidSourceFailsWithHintBeforeTouchingDeviceTooling() throws {
        let result = try run(
            ["sessions", "--source", "bogus", "--json"],
            environment: ["TOKIWATARI_BUNDLE_ID": "tokiwatari-bundle-id", "TOKIWATARI_UDID": ""],
            currentDirectory: NSTemporaryDirectory() // no .tokiwatari.json here
        )
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("invalid source: bogus") == true)
        #expect((envelope["hint"] as? String)?.firstMatch(of: /simulator.*device/) != nil)
    }

    @Test func dbFlagBypassesSourceResolutionEntirely() throws {
        let data = try asArray(try runJSON(["sessions", "--source", "device"]))
        #expect(data.count == 3) // fixture read normally, no devicectl involved
    }

    @Test func missingBundleIdFailsWithConfigurationHint() throws {
        let result = try run(
            ["sessions", "--json"],
            environment: ["TOKIWATARI_BUNDLE_ID": "", "TOKIWATARI_UDID": ""],
            currentDirectory: NSTemporaryDirectory() // no .tokiwatari.json here
        )
        #expect(result.status == 1)
        let envelope = try asDict(try parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("bundle id is not configured") == true)
        #expect((envelope["hint"] as? String)?.contains("--bundle-id") == true)
    }
}
