import Foundation
import GRDB
import Testing
@testable import TokiwatariCore

private let testUdid = "UDID-TEST-0001"
private let appBundleId = "com.example.app"
private let otherBundleId = "com.example.other"

private let backupStampMs = Int(Date().timeIntervalSince1970 * 1000)
private let backupA = DeviceCacheStore.backupPrefix + "\(backupStampMs)-11111111-1111-1111-1111-111111111111"
private let backupB = DeviceCacheStore.backupPrefix + "\(backupStampMs)-22222222-2222-2222-2222-222222222222"
private func backupName(ageMs: Double) -> String {
    DeviceCacheStore.backupPrefix + "\(Int(Date().timeIntervalSince1970 * 1000 - ageMs))-" + UUID().uuidString
}

private struct PullFailure: Error {}

private final class MoveFailer {
    private(set) var calls = 0
    private(set) var backupExistedOnFailure = false
    private let failOn: Set<Int>
    private let transactions: URL

    init(failOn: Set<Int>, transactions: URL) {
        self.failOn = failOn
        self.transactions = transactions
    }

    func move(_ from: URL, _ to: URL) throws {
        calls += 1
        if failOn.contains(calls) {
            backupExistedOnFailure = ((try? FileManager.default.contentsOfDirectory(atPath: transactions.path)) ?? [])
                .contains { $0.hasPrefix(DeviceCacheStore.backupPrefix) }
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: from, to: to)
    }
}

private struct CacheHarness {
    let root: URL
    let store: DeviceCacheStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DeviceCacheStore(root: root)
    }

    var current: URL { store.cacheDirectory(udid: testUdid, bundleId: appBundleId) }
    var transactions: URL { store.transactionsDirectory(udid: testUdid, bundleId: appBundleId) }
    var currentDb: String { current.appendingPathComponent(DatabaseContract.fileName).path }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Default is a rollback-journal db: readonly-openable with no sidecar files,
    /// so sidecar presence is exactly what the test specifies. A WAL-mode db is
    /// readonly-openable only while a -shm file exists (even a garbage one).
    @discardableResult
    func makeSnapshot(
        at directory: URL,
        userVersion: Int = 1,
        marker: String? = nil,
        walMode: Bool = false,
        walData: Data? = nil,
        shmData: Data? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent(DatabaseContract.fileName).path
        let queue = try DatabaseQueue(path: dbPath)
        try queue.writeWithoutTransaction { db in
            if walMode {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            try db.execute(sql: "CREATE TABLE t(x TEXT)")
            try db.execute(sql: "PRAGMA user_version = \(userVersion)")
        }
        try queue.close()
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        if let marker {
            try marker.write(to: directory.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        }
        if let walData { try walData.write(to: URL(fileURLWithPath: dbPath + "-wal")) }
        if let shmData { try shmData.write(to: URL(fileURLWithPath: dbPath + "-shm")) }
        return directory
    }

    func makeStaging(marker: String, userVersion: Int = 1, walData: Data? = nil, shmData: Data? = nil) throws -> URL {
        try makeSnapshot(
            at: transactions.appendingPathComponent(DeviceCacheStore.stagingPrefix + UUID().uuidString, isDirectory: true),
            userVersion: userVersion,
            marker: marker,
            walData: walData,
            shmData: shmData
        )
    }

    func marker(of directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent("marker.txt"), encoding: .utf8)
    }

    func transactionEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: transactions.path)) ?? []).sorted()
    }

    func recover(refresh: Bool) throws -> DeviceCacheRecoveryResult {
        try store.recoverInterruptedCommit(udid: testUdid, bundleId: appBundleId, refresh: refresh)
    }

    func resolve(refresh: Bool = false, pull: (String) throws -> Void) throws -> String {
        try store.resolveDbPath(
            udid: testUdid,
            bundleId: appBundleId,
            refresh: refresh,
            reuseWithinMs: 0,
            pruneOlderThanMs: 14 * 24 * 60 * 60 * 1000,
            pull: pull
        )
    }
}

struct DeviceCacheRecoveryTests {

    @Test func validCurrentWithoutRefreshDeletesBackupsButKeepsStaging() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "current")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "leftover")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent("staging-A"), marker: "concurrent")

        #expect(try h.recover(refresh: false) == .evaluateCurrent)
        #expect(h.marker(of: h.current) == "current")
        #expect(h.transactionEntries() == ["staging-A"])
        #expect(h.marker(of: h.transactions.appendingPathComponent("staging-A")) == "concurrent")
    }

    @Test func pruneRemovesExpiredStagingButKeepsFresh() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "current")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent("staging-FRESH"))
        let stale = try h.makeSnapshot(at: h.transactions.appendingPathComponent("staging-STALE"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -15 * 24 * 60 * 60)],
            ofItemAtPath: stale.path
        )

        h.store.pruneStaleEntries(olderThanMs: 14 * 24 * 60 * 60 * 1000)
        #expect(h.transactionEntries() == ["staging-FRESH"])
    }

    @Test func validCurrentWithRefreshRetainsBackupsUntilPublish() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "backup")

        guard case .pull(let retained) = try h.recover(refresh: true) else {
            Issue.record("expected .pull")
            return
        }
        #expect(retained.map(\.lastPathComponent) == [backupA])
        #expect(h.marker(of: h.current) == "old")

        // pull failure keeps both current and backup
        #expect(throws: PullFailure.self) {
            try h.resolve(refresh: true) { _ in throw PullFailure() }
        }
        #expect(h.marker(of: h.current) == "old")
        #expect(h.transactionEntries() == [backupA])

        // successful publish deletes the retained backup
        _ = try h.resolve(refresh: true) { staging in
            try h.makeSnapshot(at: URL(fileURLWithPath: staging), marker: "new")
        }
        #expect(h.marker(of: h.current) == "new")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func missingCurrentWithSingleBackupIsRestored() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "backup")

        #expect(try h.recover(refresh: false) == .evaluateCurrent)
        #expect(h.marker(of: h.current) == "backup")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func invalidCurrentWithValidBackupRestoresTheBackup() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, userVersion: 2, marker: "bad")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "good")

        #expect(try h.recover(refresh: false) == .evaluateCurrent)
        #expect(h.marker(of: h.current) == "good")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func multipleRecoverableBackupsWithoutRefreshIsAnError() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "a")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupB), marker: "b")

        #expect(throws: CliError.self) { try h.recover(refresh: false) }
        #expect(h.transactionEntries() == [backupA, backupB])
    }

    @Test func multipleBackupsWithRefreshAreRetainedUntilPublish() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "a")
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupB), marker: "b")

        #expect(throws: PullFailure.self) {
            try h.resolve(refresh: true) { _ in throw PullFailure() }
        }
        #expect(h.transactionEntries() == [backupA, backupB])

        _ = try h.resolve(refresh: true) { staging in
            try h.makeSnapshot(at: URL(fileURLWithPath: staging), marker: "new")
        }
        #expect(h.marker(of: h.current) == "new")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func invalidBackupsAreNotRestoreCandidates() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try FileManager.default.createDirectory(
            at: h.transactions.appendingPathComponent(backupA), withIntermediateDirectories: true
        ) // no db file
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupB), userVersion: 2)

        guard case .pull(let retained) = try h.recover(refresh: false) else {
            Issue.record("expected .pull")
            return
        }
        #expect(retained.map(\.lastPathComponent) == [backupA, backupB])
        #expect(h.transactionEntries() == [backupA, backupB])
    }

    @Test func otherBundleIdsBackupIsNotACandidate() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let otherTx = h.store.transactionsDirectory(udid: testUdid, bundleId: otherBundleId)
        try h.makeSnapshot(at: otherTx.appendingPathComponent(backupA), marker: "other")

        #expect(try h.recover(refresh: false) == .pull(retainedBackups: []))
        #expect(h.marker(of: otherTx.appendingPathComponent(backupA)) == "other")
    }

    @Test func freshBackupOfOldCurrentSurvivesPrune() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let backup = try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), marker: "backup")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -15 * 24 * 60 * 60)],
            ofItemAtPath: backup.path
        )

        h.store.pruneStaleEntries(olderThanMs: 14 * 24 * 60 * 60 * 1000)
        #expect(h.transactionEntries() == [backupA])
    }

    @Test func backupExpiredByItsNameTimestampIsPruned() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupName(ageMs: 15 * 24 * 60 * 60 * 1000)))

        h.store.pruneStaleEntries(olderThanMs: 14 * 24 * 60 * 60 * 1000)
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func malformedBackupNameFailsRecovery() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.transactions.appendingPathComponent("backup-legacy"))

        #expect(throws: CliError.self) { try h.recover(refresh: false) }
        #expect(h.transactionEntries() == ["backup-legacy"])
    }

    @Test func backupNameValidationRejectsMalformedForms() {
        #expect(DeviceCacheStore.backupCreationMs(backupA) == Int64(backupStampMs))
        for name in [
            "backup-123-not-a-uuid",
            "backup-123-",
            "backup-123",
            "backup--11111111-1111-1111-1111-111111111111",
            "backup-" + String(repeating: "9", count: 40) + "-11111111-1111-1111-1111-111111111111",
        ] {
            #expect(DeviceCacheStore.backupCreationMs(name) == nil, "expected nil for \(name)")
        }
    }
}

struct DeviceCacheCommitTests {

    @Test func commitReplacesDbWalAndShmTogether() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old", walData: Data("old-wal".utf8), shmData: Data("old-shm".utf8))
        let staging = try h.makeStaging(marker: "new", walData: Data("new-wal".utf8), shmData: Data("new-shm".utf8))

        try h.store.commitStagedDeviceSnapshot(staging: staging, udid: testUdid, bundleId: appBundleId)

        #expect(h.marker(of: h.current) == "new")
        #expect(try Data(contentsOf: URL(fileURLWithPath: h.currentDb + "-wal")) == Data("new-wal".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: h.currentDb + "-shm")) == Data("new-shm".utf8))
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func commitWithoutWalLeavesNoStaleWal() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old", walData: Data("old-wal".utf8))
        let staging = try h.makeStaging(marker: "new")

        try h.store.commitStagedDeviceSnapshot(staging: staging, udid: testUdid, bundleId: appBundleId)

        #expect(h.marker(of: h.current) == "new")
        #expect(!FileManager.default.fileExists(atPath: h.currentDb + "-wal"))
    }

    @Test func pullThatWritesNoDbLeavesCacheIntact() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old")

        #expect(throws: CliError.self) {
            try h.resolve { _ in }
        }
        #expect(h.marker(of: h.current) == "old")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func invalidPulledSnapshotLeavesCacheIntact() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old")

        #expect(throws: CliError.self) {
            try h.resolve { staging in
                try h.makeSnapshot(at: URL(fileURLWithPath: staging), userVersion: 2, marker: "new")
            }
        }
        #expect(h.marker(of: h.current) == "old")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func containmentGuardRejectsForeignStaging() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let outside = try h.makeSnapshot(at: h.root.appendingPathComponent("evil-staging"), marker: "evil")
        #expect(throws: CliError.self) {
            try h.store.commitStagedDeviceSnapshot(staging: outside, udid: testUdid, bundleId: appBundleId)
        }
        let wrongPrefix = try h.makeSnapshot(at: h.transactions.appendingPathComponent("evil-x"), marker: "evil")
        #expect(throws: CliError.self) {
            try h.store.commitStagedDeviceSnapshot(staging: wrongPrefix, udid: testUdid, bundleId: appBundleId)
        }
    }

    @Test func failedPublishWithSuccessfulRollbackRestoresOldCurrent() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old")
        let staging = try h.makeStaging(marker: "new")

        let failer = MoveFailer(failOn: [2], transactions: h.transactions)
        var store = DeviceCacheStore(root: h.root)
        store.operations.moveItem = failer.move

        #expect(throws: CliError.self) {
            try store.commitStagedDeviceSnapshot(staging: staging, udid: testUdid, bundleId: appBundleId)
        }
        #expect(failer.backupExistedOnFailure)
        #expect(h.marker(of: h.current) == "old")
        #expect(h.transactionEntries().isEmpty)
    }

    @Test func failedPublishAndFailedRollbackKeepTheBackup() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try h.makeSnapshot(at: h.current, marker: "old")
        let staging = try h.makeStaging(marker: "new")

        let failer = MoveFailer(failOn: [2, 3], transactions: h.transactions)
        var store = DeviceCacheStore(root: h.root)
        store.operations.moveItem = failer.move

        #expect(throws: CliError.self) {
            try store.commitStagedDeviceSnapshot(staging: staging, udid: testUdid, bundleId: appBundleId)
        }
        let backups = h.transactionEntries().filter { $0.hasPrefix(DeviceCacheStore.backupPrefix) }
        #expect(backups.count == 1)
        #expect(DeviceCacheStore.backupCreationMs(backups[0]) != nil)
        #expect(h.marker(of: h.transactions.appendingPathComponent(backups[0])) == "old")
        #expect(!FileManager.default.fileExists(atPath: h.current.path))
    }
}

struct DeviceCachePermissionTests {
    private func posixPermissions(_ path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test func resolveRestrictsDirectoriesAndPulledFiles() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        _ = try h.resolve { staging in
            try h.makeSnapshot(at: URL(fileURLWithPath: staging), marker: "new", walData: Data("w".utf8))
        }
        #expect(posixPermissions(h.root.path) == 0o700)
        #expect(posixPermissions(h.current.path) == 0o700)
        #expect(posixPermissions(h.currentDb) == 0o600)
        #expect(posixPermissions(h.currentDb + "-wal") == 0o600)
    }

    @Test func existingLooseRootIsTightenedOnResolve() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.root.path)
        _ = try h.resolve { staging in
            try h.makeSnapshot(at: URL(fileURLWithPath: staging), marker: "new")
        }
        #expect(posixPermissions(h.root.path) == 0o700)
    }
}

struct SnapshotValidationTests {

    @Test func healthySnapshotPasses() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let dir = try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA))
        #expect(h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: false))
    }

    @Test func userVersionMismatchFails() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let dir = try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), userVersion: 2)
        #expect(!h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: true))
    }

    @Test func corruptDbFails() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let dir = h.transactions.appendingPathComponent(backupA)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a sqlite database at all".utf8)
            .write(to: dir.appendingPathComponent(DatabaseContract.fileName))
        #expect(!h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: true))
    }

    @Test func garbageWalSidecarsDoNotFailValidation() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let dir = try h.makeSnapshot(
            at: h.transactions.appendingPathComponent(backupA),
            walMode: true,
            walData: Data("garbage that is not a valid wal frame".utf8),
            shmData: Data("garbage that is not a valid shm index".utf8)
        )
        #expect(h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: false))
        #expect(h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: true))
    }

    @Test func walDbWithoutSidecarsNeedsWritableRecovery() throws {
        let h = try CacheHarness()
        defer { h.cleanup() }
        let dir = try h.makeSnapshot(at: h.transactions.appendingPathComponent(backupA), walMode: true)

        #expect(!h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: false))
        #expect(h.store.validateRecoverableSnapshot(directory: dir, allowWritableRecovery: true))
    }
}
