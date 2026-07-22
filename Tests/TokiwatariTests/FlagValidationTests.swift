import Foundation
import Testing

@Suite struct FlagValidationTests {
    private func runWithDb(_ arguments: [String]) throws -> CLIResult {
        try run(arguments + ["--db", Fixture.shared.db])
    }

    @Test func sessionsLimitIsValidatedOnBothSides() throws {
        for bad in ["--limit=-1", "--limit=0", "--limit=10001"] {
            let result = try runWithDb(["sessions", bad])
            #expect(result.status == 1, "expected exit 1 for \(bad)")
            #expect(result.stderr.contains("invalid --limit"))
        }
        try runOk(["sessions", "--limit=1"])
        try runOk(["sessions", "--limit=10000"])
    }

    @Test func everyListCommandValidatesLimit() throws {
        for command in ["timeline", "ui", "api"] {
            let result = try runWithDb([command, "--limit=0"])
            #expect(result.status == 1, "expected exit 1 for \(command)")
            #expect(result.stderr.contains("invalid --limit"))
            try runOk([command, "--limit=1"])
        }
    }

    @Test func aroundAllowsZeroAndCapsAtTenThousand() throws {
        let ok = try runOk(["around", "8", "--before=0", "--after=0"])
        #expect(lines(ok.stdout).count == 3) // session header + column header + the center event only
        for bad in ["--before=-1", "--before=10001", "--after=-1", "--after=10001"] {
            let result = try runWithDb(["around", "8", bad])
            #expect(result.status == 1, "expected exit 1 for \(bad)")
        }
        try runOk(["around", "8", "--before=10000", "--after=10000"])
    }

    @Test func timeAndFilterFlagsRejectNegatives() throws {
        #expect(try runWithDb(["around", "8", "--before-ms=-1"]).status == 1)
        #expect(try runWithDb(["around", "8", "--after-ms=-1"]).status == 1)
        #expect(try runWithDb(["api", "--min-duration-ms=-1"]).status == 1)
        try runOk(["around", "8", "--before-ms=0", "--after-ms=0"])
        try runOk(["api", "--min-duration-ms=0"])
    }

    @Test func validationErrorsKeepTheJSONEnvelope() throws {
        let result = try runWithDb(["sessions", "--limit=-1", "--json"])
        #expect(result.status == 1)
        let envelope = try asDict(parseJSON(result.stdout))
        #expect((envelope["error"] as? String)?.contains("invalid --limit") == true)
        #expect(envelope["hint"] as? String != nil)
    }
}
