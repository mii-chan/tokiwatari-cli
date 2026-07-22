import Foundation
import GRDB

enum DeviceCacheRecoveryResult: Equatable {
    /// Use current as the freshness-check candidate (not necessarily adopted).
    case evaluateCurrent
    /// Pull a new snapshot; delete `retainedBackups` only after the new current is published.
    case pull(retainedBackups: [URL])
}

/// Injectable subset of file operations so tests can fault-inject individual renames.
struct DeviceCacheFileOperations {
    var moveItem: (URL, URL) throws -> Void
    var removeItem: (URL) throws -> Void
    var fileExists: (String) -> Bool

    static var live: DeviceCacheFileOperations {
        DeviceCacheFileOperations(
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }
}

/// Local cache of device snapshots, laid out as:
///
///     <root>/<udid>/<bundleId>/                                        published generation
///     <root>/<udid>/.transactions/<bundleId>/staging-<UUID>/           pull destination
///     <root>/<udid>/.transactions/<bundleId>/backup-<unix-ms>-<UUID>/  previous generation during commit
struct DeviceCacheStore {
    static let transactionsDirName = ".transactions"
    static let stagingPrefix = "staging-"
    static let backupPrefix = "backup-"

    /// Renames preserve directory mtime, so backup age lives in the name: backup-<unix-ms>-<UUID>.
    static func backupCreationMs(_ name: String) -> Int64? {
        guard name.hasPrefix(backupPrefix) else { return nil }
        let rest = name.dropFirst(backupPrefix.count)
        guard let separator = rest.firstIndex(of: "-") else { return nil }
        let stamp = rest[..<separator]
        guard !stamp.isEmpty, stamp.allSatisfy({ $0.isASCII && $0.isNumber }),
              let ms = Int64(stamp),
              UUID(uuidString: String(rest[rest.index(after: separator)...])) != nil
        else { return nil }
        return ms
    }

    let root: URL
    var operations: DeviceCacheFileOperations = .live

    func cacheDirectory(udid: String, bundleId: String) -> URL {
        root.appendingPathComponent(udid, isDirectory: true)
            .appendingPathComponent(bundleId, isDirectory: true)
    }

    func transactionsDirectory(udid: String, bundleId: String) -> URL {
        root.appendingPathComponent(udid, isDirectory: true)
            .appendingPathComponent(Self.transactionsDirName, isDirectory: true)
            .appendingPathComponent(bundleId, isDirectory: true)
    }

    func resolveDbPath(
        udid: String,
        bundleId: String,
        refresh: Bool,
        reuseWithinMs: Double,
        pruneOlderThanMs: Double,
        pull: (String) throws -> Void
    ) throws -> String {
        let current = cacheDirectory(udid: udid, bundleId: bundleId)
        let dbPath = current.appendingPathComponent(DatabaseContract.fileName).path

        try prepareRoot()
        var retainedBackups: [URL] = []
        switch try recoverInterruptedCommit(udid: udid, bundleId: bundleId, refresh: refresh) {
        case .evaluateCurrent:
            if !refresh,
               let modified = (try? FileManager.default.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) * 1000 < reuseWithinMs {
                return dbPath
            }
        case .pull(let backups):
            retainedBackups = backups
        }

        let transactions = transactionsDirectory(udid: udid, bundleId: bundleId)
        try FileManager.default.createDirectory(
            at: transactions, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let staging = transactions.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? operations.removeItem(staging) }

        try pull(staging.path)
        try restrictSnapshotFiles(in: staging)

        guard validateRecoverableSnapshot(directory: staging, allowWritableRecovery: true) else {
            throw CliError(
                "pulled device snapshot failed validation for \(bundleId)",
                "The pulled file is not a usable \(DatabaseContract.fileName) (schema user_version=\(DatabaseContract.expectedUserVersion) expected). The existing cache was left unchanged; retry with --refresh, or fall back to --db <path> with an exported snapshot."
            )
        }

        try commitStagedDeviceSnapshot(staging: staging, udid: udid, bundleId: bundleId)
        for backup in retainedBackups {
            try ensureRemovable(backup, expectedParent: transactions, namePrefix: Self.backupPrefix)
            try? operations.removeItem(backup)
        }

        // mtime = pull time, so the freshness check works regardless of the file's original mtime on the device.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dbPath)
        pruneStaleEntries(olderThanMs: pruneOlderThanMs)
        return dbPath
    }

    /// Snapshots hold recorded request/response bodies; forcing the root to 0700
    /// every run shields pre-existing caches without a per-file migration.
    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch {
            throw CliError(
                "failed to restrict device cache permissions at \(root.path): \(error)",
                "Check the ownership and permissions of the directory, or remove it and re-run."
            )
        }
    }

    private func restrictSnapshotFiles(in directory: URL) throws {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name).path
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            } catch {
                throw CliError(
                    "failed to restrict permissions on the pulled snapshot file \(path): \(error)",
                    "Check the ownership and permissions of the device cache at \(root.path), or remove it and re-run."
                )
            }
        }
    }

    /// Repair leftovers from a commit interrupted between its two renames
    /// (current -> backup, staging -> current), which are not atomic as a whole.
    /// staging-* is left alone: it may belong to a concurrent pull; expired ones go via prune.
    func recoverInterruptedCommit(udid: String, bundleId: String, refresh: Bool) throws -> DeviceCacheRecoveryResult {
        let current = cacheDirectory(udid: udid, bundleId: bundleId)
        let transactions = transactionsDirectory(udid: udid, bundleId: bundleId)
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: transactions.path)) ?? []).sorted()
        let backups = entries.filter { $0.hasPrefix(Self.backupPrefix) }
            .map { transactions.appendingPathComponent($0) }
        if let malformed = backups.first(where: { Self.backupCreationMs($0.lastPathComponent) == nil }) {
            throw CliError(
                "unrecognized backup entry in the device cache: \(malformed.path)",
                "Remove \(transactions.path) manually and re-run."
            )
        }

        if refresh {
            return .pull(retainedBackups: backups)
        }

        let currentIsValid = operations.fileExists(current.appendingPathComponent(DatabaseContract.fileName).path)
            && (backups.isEmpty || validateRecoverableSnapshot(directory: current, allowWritableRecovery: false))

        if currentIsValid {
            for backup in backups {
                try ensureRemovable(backup, expectedParent: transactions, namePrefix: Self.backupPrefix)
                try? operations.removeItem(backup)
            }
            return .evaluateCurrent
        }

        let recoverable = backups.filter { isRecoverableBackup($0) }
        if recoverable.isEmpty {
            return .pull(retainedBackups: backups)
        }
        if recoverable.count > 1 {
            throw CliError(
                "multiple recoverable backups found in the device cache for \(bundleId)",
                "Re-run with --refresh to pull a fresh snapshot, or remove \(transactions.path) manually."
            )
        }
        if operations.fileExists(current.path) {
            try ensureRemovable(current, expectedParent: current.deletingLastPathComponent(), namePrefix: nil)
            try operations.removeItem(current)
        }
        try ensureRemovable(recoverable[0], expectedParent: transactions, namePrefix: Self.backupPrefix)
        try operations.moveItem(recoverable[0], current)
        for backup in backups where backup != recoverable[0] {
            try ensureRemovable(backup, expectedParent: transactions, namePrefix: Self.backupPrefix)
            try? operations.removeItem(backup)
        }
        return .evaluateCurrent
    }

    func commitStagedDeviceSnapshot(staging: URL, udid: String, bundleId: String) throws {
        let current = cacheDirectory(udid: udid, bundleId: bundleId)
        let transactions = transactionsDirectory(udid: udid, bundleId: bundleId)
        let backup = transactions.appendingPathComponent(
            Self.backupPrefix + "\(Int(Date().timeIntervalSince1970 * 1000))-" + UUID().uuidString,
            isDirectory: true
        )

        try ensureRemovable(staging, expectedParent: transactions, namePrefix: Self.stagingPrefix)
        try ensureRemovable(backup, expectedParent: transactions, namePrefix: Self.backupPrefix)
        try ensureRemovable(current, expectedParent: current.deletingLastPathComponent(), namePrefix: nil)

        var publishedNewCurrent = false
        var restoredOldCurrent = false
        defer {
            try? operations.removeItem(staging)
            // The backup is the last good snapshot: delete it only once a current is in place.
            if publishedNewCurrent || restoredOldCurrent {
                try? operations.removeItem(backup)
            }
        }

        var movedCurrentAside = false
        if operations.fileExists(current.path) {
            try operations.moveItem(current, backup)
            movedCurrentAside = true
        }
        do {
            try operations.moveItem(staging, current)
            publishedNewCurrent = true
        } catch {
            if movedCurrentAside {
                do {
                    try operations.moveItem(backup, current)
                    restoredOldCurrent = true
                } catch {
                    throw CliError(
                        "failed to publish the pulled snapshot and to restore the previous cache for \(bundleId)",
                        "The previous snapshot is kept at \(backup.path); the next run recovers it automatically."
                    )
                }
            }
            throw CliError(
                "failed to publish the pulled snapshot for \(bundleId): \(error)",
                "Re-run the command; the previous device cache was left in place."
            )
        }
    }

    /// A snapshot is usable when it opens readonly with the expected user_version and a
    /// clean quick_check. Staging/backup areas are disposable pre-publication copies, so
    /// `allowWritableRecovery` may run WAL recovery on them first.
    func validateRecoverableSnapshot(directory: URL, allowWritableRecovery: Bool) -> Bool {
        let dbPath = directory.appendingPathComponent(DatabaseContract.fileName).path
        guard operations.fileExists(dbPath) else { return false }
        if snapshotPassesReadonlyChecks(dbPath) { return true }
        guard allowWritableRecovery else { return false }
        do {
            let recovery = try DatabaseQueue(path: dbPath)
            defer { try? recovery.close() }
            _ = try recovery.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        } catch {
            return false
        }
        return snapshotPassesReadonlyChecks(dbPath)
    }

    func pruneStaleEntries(olderThanMs: Double) {
        let fileManager = FileManager.default
        for udidName in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            let udidDir = root.appendingPathComponent(udidName, isDirectory: true)
            for entryName in (try? fileManager.contentsOfDirectory(atPath: udidDir.path)) ?? [] {
                let entry = udidDir.appendingPathComponent(entryName, isDirectory: true)
                if entryName == Self.transactionsDirName {
                    pruneTransactions(entry, olderThanMs: olderThanMs)
                    continue
                }
                let dbPath = entry.appendingPathComponent(DatabaseContract.fileName).path
                let modified = (try? fileManager.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date
                if let modified, Date().timeIntervalSince(modified) * 1000 < olderThanMs { continue }
                guard (try? ensureRemovable(entry, expectedParent: udidDir, namePrefix: nil)) != nil else { continue }
                try? operations.removeItem(entry)
            }
            if ((try? fileManager.contentsOfDirectory(atPath: udidDir.path)) ?? []).isEmpty,
               (try? ensureRemovable(udidDir, expectedParent: root, namePrefix: nil)) != nil {
                try? operations.removeItem(udidDir)
            }
        }
    }

    private func pruneTransactions(_ transactionsRoot: URL, olderThanMs: Double) {
        let fileManager = FileManager.default
        for bundleName in (try? fileManager.contentsOfDirectory(atPath: transactionsRoot.path)) ?? [] {
            let bundleDir = transactionsRoot.appendingPathComponent(bundleName, isDirectory: true)
            for entryName in (try? fileManager.contentsOfDirectory(atPath: bundleDir.path)) ?? [] {
                let entry = bundleDir.appendingPathComponent(entryName, isDirectory: true)
                let prefix: String
                if entryName.hasPrefix(Self.backupPrefix) {
                    guard let createdMs = Self.backupCreationMs(entryName),
                          Date().timeIntervalSince1970 * 1000 - Double(createdMs) >= olderThanMs
                    else { continue }
                    prefix = Self.backupPrefix
                } else if entryName.hasPrefix(Self.stagingPrefix) {
                    let modified = (try? fileManager.attributesOfItem(atPath: entry.path))?[.modificationDate] as? Date
                    if let modified, Date().timeIntervalSince(modified) * 1000 < olderThanMs { continue }
                    prefix = Self.stagingPrefix
                } else {
                    continue
                }
                guard (try? ensureRemovable(entry, expectedParent: bundleDir, namePrefix: prefix)) != nil else { continue }
                try? operations.removeItem(entry)
            }
            if ((try? fileManager.contentsOfDirectory(atPath: bundleDir.path)) ?? []).isEmpty {
                try? operations.removeItem(bundleDir)
            }
        }
        if ((try? fileManager.contentsOfDirectory(atPath: transactionsRoot.path)) ?? []).isEmpty {
            try? operations.removeItem(transactionsRoot)
        }
    }

    private func isRecoverableBackup(_ url: URL) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
              type == .typeDirectory
        else { return false }
        return validateRecoverableSnapshot(directory: url, allowWritableRecovery: true)
    }

    private func snapshotPassesReadonlyChecks(_ dbPath: String) -> Bool {
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: dbPath, configuration: configuration) else { return false }
        defer { try? queue.close() }
        let ok = try? queue.read { db -> Bool in
            guard try Int.fetchOne(db, sql: "PRAGMA user_version") == DatabaseContract.expectedUserVersion else { return false }
            return try String.fetchAll(db, sql: "PRAGMA quick_check(1)") == ["ok"]
        }
        return ok ?? false
    }

    /// Containment guard for every destructive operation (Release-safe: guard + throw).
    /// `namePrefix == nil` means a published generation, whose name must not be reserved.
    private func ensureRemovable(_ target: URL, expectedParent: URL, namePrefix: String?) throws {
        let rootPath = resolvedPath(root)
        let parentPath = resolvedPath(expectedParent)
        let name = target.lastPathComponent
        let refusal = CliError(
            "refusing to modify an unexpected device cache path: \(target.path)",
            "The device cache at \(root.path) looks corrupted; remove it manually and re-run."
        )
        guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/"),
              resolvedPath(target.deletingLastPathComponent()) == parentPath,
              !name.isEmpty, name != ".", name != "..", !name.contains("/")
        else { throw refusal }
        if let namePrefix {
            guard name.hasPrefix(namePrefix) else { throw refusal }
        } else {
            guard !name.hasPrefix(".") else { throw refusal }
        }
        if let type = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType {
            guard type == .typeDirectory else { throw refusal }
        }
    }

    /// `standardizedFileURL` alone resolves only "..", not symlinks in existing ancestors.
    private func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
