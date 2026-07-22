import Foundation
import Testing

@Suite struct ParseErrorSanitizationTests {

    @Test func invalidValueDiagnosticsAreSanitized() throws {
        let result = try run(["sessions", "--limit=evil\u{001B}[31m\u{202E}", "--db", Fixture.shared.db])
        #expect(result.status == 64)
        #expect(result.stderr.contains("\\u001b"))
        #expect(result.stderr.contains("\\u202e"))
        #expect(!result.stderr.unicodeScalars.contains("\u{001B}"))
        #expect(!result.stderr.unicodeScalars.contains("\u{202E}"))
        #expect(result.stdout.isEmpty)
    }

    @Test func unknownOptionDiagnosticsAreSanitized() throws {
        let result = try run(["sessions", "--nope\u{202E}evil"])
        #expect(result.status == 64)
        #expect(result.stderr.contains("\\u202e"))
        #expect(!result.stderr.unicodeScalars.contains("\u{202E}"))
    }

    @Test func helpStaysOnStdoutWithExitZero() throws {
        let result = try run(["--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("USAGE"))
        #expect(result.stderr.isEmpty)
    }

    @Test func subcommandHelpStaysOnStdoutWithExitZero() throws {
        let result = try run(["sessions", "--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("--limit"))
        #expect(result.stderr.isEmpty)
    }

    @Test func versionStaysOnStdoutWithExitZero() throws {
        let result = try run(["--version"])
        #expect(result.status == 0)
        #expect(!lines(result.stdout).isEmpty)
        #expect(result.stderr.isEmpty)
    }
}
