import Foundation
import Testing

@Suite struct BidiEscapeTests {

    @Test func bidiControlsAreEscapedInTextOutput() throws {
        let result = try runOk(["query", "SELECT char(8238) AS c, char(1564) AS d"])
        #expect(result.stdout.contains("\\u202e"))
        #expect(result.stdout.contains("\\u061c"))
        #expect(!result.stdout.unicodeScalars.contains("\u{202E}"))
        #expect(!result.stdout.unicodeScalars.contains("\u{061C}"))
    }

    @Test func bidiControlsAreEscapedInJSONOutput() throws {
        let result = try runOk(["query", "SELECT char(8238) AS c", "--json"])
        #expect(result.stdout.contains("\\u202e"))
        #expect(!result.stdout.unicodeScalars.contains("\u{202E}"))
        // The escape decodes back to the original character for JSON consumers.
        let value = try asDict(asArray(parseJSON(result.stdout)).first)["c"] as? String
        #expect(value?.unicodeScalars.contains("\u{202E}") == true)
    }

    @Test func bidiControlsAreEscapedInJSONErrors() throws {
        let result = try run(["timeline", "--session", "evil\u{202E}session", "--json", "--db", Fixture.shared.db])
        #expect(result.status == 1)
        #expect(result.stdout.contains("\\u202e"))
        #expect(!result.stdout.unicodeScalars.contains("\u{202E}"))
    }

    @Test func bidiControlsAreEscapedInTextErrors() throws {
        let result = try run(["timeline", "--session", "evil\u{061C}session", "--db", Fixture.shared.db])
        #expect(result.status == 1)
        #expect(result.stderr.contains("\\u061c"))
        #expect(!result.stderr.unicodeScalars.contains("\u{061C}"))
    }

    @Test func doctorEscapesControlCharactersInTextOutput() throws {
        let result = try run(["doctor", "--db", "/nonexistent/dir\u{202E}x/db.sqlite"])
        #expect(result.status == 1)
        #expect(result.stdout.contains("\\u202e"))
        #expect(!result.stdout.unicodeScalars.contains("\u{202E}"))
    }
}
