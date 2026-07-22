import Testing
@testable import TokiwatariCore

struct InProcessImportTests {
    @Test func executableTargetIsImportable() {
        #expect(DatabaseContract.expectedUserVersion == 1)
    }
}
