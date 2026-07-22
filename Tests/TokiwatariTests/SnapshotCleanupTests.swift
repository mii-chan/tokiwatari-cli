import Foundation
import Testing

@Suite struct SnapshotCleanupTests {
    private struct Dirs {
        let base: URL
        let tmp: URL
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func leftovers() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
                .filter { $0.hasPrefix("tokiwatari-") }
        }
    }

    private func makeDirs() throws -> Dirs {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-cleanup-\(UUID().uuidString)", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return Dirs(base: base, tmp: tmp)
    }

    @Test func errorPathLeavesNoSnapshotTempDir() throws {
        let dirs = try makeDirs()
        defer { dirs.cleanup() }
        let junk = dirs.base.appendingPathComponent("junk.sqlite")
        try Data("this is not a sqlite database".utf8).write(to: junk)

        let result = try run(["sessions", "--db", junk.path], environment: ["TMPDIR": dirs.tmp.path + "/"])
        #expect(result.status == 1)
        #expect(dirs.leftovers().isEmpty)
    }

    @Test func walFallbackSucceedsAndCleansUp() throws {
        // A WAL-mode db copied without its -shm sidecar cannot be opened readonly,
        // forcing the snapshot fallback + writable recovery on the temp copy.
        let dirs = try makeDirs()
        defer { dirs.cleanup() }
        let dbCopy = dirs.base.appendingPathComponent("tokiwatari_debug_events.sqlite")
        try FileManager.default.copyItem(atPath: Fixture.shared.db, toPath: dbCopy.path)

        let result = try run(["sessions", "--json", "--db", dbCopy.path], environment: ["TMPDIR": dirs.tmp.path + "/"])
        #expect(result.status == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(dirs.leftovers().isEmpty)
    }
}
