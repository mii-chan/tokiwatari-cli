import Foundation
import GRDB
import Testing
@testable import TokiwatariCore

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

// The fixture holds 43 events in total.
@Suite struct QueryMaxRowsTests {
    private let allRows = "SELECT session_sequence FROM events"

    @Test func exactlyMaxRowsEmitsNoNotice() throws {
        let result = try runOk(["query", allRows, "--max-rows=43"])
        #expect(lines(result.stdout).count == 44) // column header + 43 rows
        #expect(!result.stdout.contains("truncated"))
        #expect(result.stderr.isEmpty)
    }

    @Test func exceedingMaxRowsTruncatesWithTrailingNotice() throws {
        let result = try runOk(["query", allRows, "--max-rows=42"])
        let output = lines(result.stdout)
        #expect(output.count == 44) // column header + 42 rows + notice line
        #expect(output.last?.contains("truncated at 42 rows") == true)
    }

    @Test func jsonKeepsTheArrayContractAndNoticesOnStderr() throws {
        let truncatedRun = try runOk(["query", allRows, "--max-rows=42", "--json"])
        #expect(try asArray(parseJSON(truncatedRun.stdout)).count == 42)
        #expect(truncatedRun.stderr.contains("truncated at 42 rows"))

        let fullRun = try runOk(["query", allRows, "--max-rows=43", "--json"])
        #expect(try asArray(parseJSON(fullRun.stdout)).count == 43)
        #expect(fullRun.stderr.isEmpty)
    }

    @Test func maxRowsBoundsAreEnforced() throws {
        for bad in ["--max-rows=0", "--max-rows=100001"] {
            let result = try run(["query", allRows, bad, "--db", Fixture.shared.db])
            #expect(result.status == 1, "expected exit 1 for \(bad)")
            #expect(result.stderr.contains("invalid --max-rows"))
        }
        try runOk(["query", allRows, "--max-rows=1", "--json"])
        try runOk(["query", allRows, "--max-rows=100000"])
    }
}

// The 64 MiB budget is a fixed constant, so these tests generate real multi-megabyte rows.
@Suite struct QueryResultBudgetTests {
    // Rows cost 2097344 each: 31 fit under 64 MiB, the 32nd trips the budget.
    private let fortyBigRows =
        "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<40) SELECT zeroblob(2097152) AS b FROM r"
    private let thirtyTwoBigColumns =
        "SELECT " + (0..<32).map { "zeroblob(2097152) AS c\($0)" }.joined(separator: ", ")

    @Test func estimatedCostChargesFixedCostsForEmptyValues() {
        let row: Row = ["a": nil, "b": "", "c": 3, "d": 1.5]
        #expect(estimatedRowCost(row, remainingBudget: .max) == 128 + 4 * 64 + 8 + 8)
    }

    @Test func estimatedCostCountsStringAndBlobBytes() {
        let row: Row = ["s": "abcd", "d": Data([1, 2, 3])]
        #expect(estimatedRowCost(row, remainingBudget: .max) == 128 + 2 * 64 + 4 + 3)
    }

    @Test func estimatedCostIsNilOverBudgetAndExactBudgetPasses() {
        let row: Row = ["s": "abcd"]
        #expect(estimatedRowCost(row, remainingBudget: 128 + 64 + 3) == nil)
        #expect(estimatedRowCost(row, remainingBudget: 128 + 64 + 4) == 128 + 64 + 4)
    }

    @Test func resultColumnsAreCappedAtThirtyTwo() throws {
        try runOk(["query", "SELECT " + (0..<32).map { "1 AS c\($0)" }.joined(separator: ", ")])
        let result = try run(
            ["query", "SELECT " + (0..<33).map { "1 AS c\($0)" }.joined(separator: ", "), "--db", Fixture.shared.db]
        )
        #expect(result.status == 1)
        #expect(result.stderr.contains("too many result columns"))
    }

    @Test func firstRowOverBudgetIsAnError() throws {
        let result = try run(["query", thirtyTwoBigColumns, "--db", Fixture.shared.db])
        #expect(result.status == 1)
        #expect(result.stderr.contains("first query result row exceeds the result memory budget"))
        #expect(result.stderr.contains("hint:"))
    }

    @Test func midStreamBudgetReturnsPartialRowsWithNotice() throws {
        let result = try runOk(["query", fortyBigRows])
        let output = lines(result.stdout)
        #expect(output.count == 33) // column header + 31 rows + notice
        #expect(result.stdout.contains("<blob 2097152B>"))
        #expect(output.last?.contains("result truncated after 31 rows") == true)
        #expect(output.last?.contains("result memory budget") == true)
        // Not user-adjustable, so the notice must not suggest --max-rows.
        #expect(output.last?.contains("--max-rows") == false)
    }

    @Test func jsonBudgetTruncationKeepsValidArrayAndNoticesOnStderr() throws {
        let result = try runOk(["query", fortyBigRows, "--json"])
        #expect(try asArray(parseJSON(result.stdout)).count == 31)
        #expect(result.stderr.contains("result truncated after 31 rows"))
        #expect(!result.stderr.contains("--max-rows"))
    }
}
