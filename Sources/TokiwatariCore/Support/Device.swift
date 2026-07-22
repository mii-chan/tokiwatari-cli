import Foundation

struct ConnectedDevice {
    let udid: String
    let name: String
}

private enum DeviceCache {
    /// Reuse a pulled snapshot for this long; `--refresh` forces a new pull.
    static let pullTTLMs: Double = 5_000

    /// Entries not pulled for this long are pruned after each pull (db mtime = pull time).
    static let pruneTTLMs: Double = 14 * 24 * 60 * 60 * 1000
}

private func deviceCacheRoot() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".cache/tokiwatari/device")
}

private func pruneStaleDeviceCaches() {
    let fileManager = FileManager.default
    let root = deviceCacheRoot()
    for udid in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] {
        let udidDir = (root as NSString).appendingPathComponent(udid)
        for bundleId in (try? fileManager.contentsOfDirectory(atPath: udidDir)) ?? [] {
            let entryDir = (udidDir as NSString).appendingPathComponent(bundleId)
            let dbPath = (entryDir as NSString).appendingPathComponent(DatabaseContract.fileName)
            let modified = (try? fileManager.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) * 1000 < DeviceCache.pruneTTLMs { continue }
            try? fileManager.removeItem(atPath: entryDir)
        }
        if ((try? fileManager.contentsOfDirectory(atPath: udidDir)) ?? []).isEmpty {
            try? fileManager.removeItem(atPath: udidDir)
        }
    }
}

func listConnectedDevices() throws -> [ConnectedDevice] {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tokiwatari-devicectl-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let jsonPath = tmpDir.appendingPathComponent("devices.json").path

    do {
        try xcrun(["devicectl", "list", "devices", "--json-output", jsonPath])
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = parsed["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { device -> ConnectedDevice? in
            let connection = device["connectionProperties"] as? [String: Any]
            let tunnelState = (connection?["tunnelState"] as? String ?? "").lowercased()
            guard tunnelState == "connected" else { return nil }
            let hardware = device["hardwareProperties"] as? [String: Any]
            let properties = device["deviceProperties"] as? [String: Any]
            guard let udid = (hardware?["udid"] as? String) ?? (device["identifier"] as? String),
                  !udid.isEmpty
            else { return nil }
            return ConnectedDevice(udid: udid, name: properties?["name"] as? String ?? "unknown")
        }
    } catch let e as ProcessFailure {
        throw CliError(
            "failed to run devicectl: \(e.stderr.isEmpty ? e.message : e.stderr)",
            "devicectl requires Xcode 15+. Try `xcrun devicectl list devices`, or bypass with the manual export route: share a snapshot from the app (Tokiwatari.exportSnapshot) and read it with --db <path>."
        )
    }
}

/// Pick the target device UDID: explicit udid, or the single connected device.
private func resolveDeviceUdid(_ explicitUdid: String?) throws -> String {
    if let explicitUdid { return explicitUdid }
    let connected = try listConnectedDevices()
    if connected.isEmpty {
        throw CliError(
            "no connected device found",
            "Connect the iPhone via USB (trusted + Developer Mode enabled), pass --udid <udid> (`xcrun devicectl list devices`), or fall back to --db <path> with an exported snapshot."
        )
    }
    if connected.count > 1 {
        let candidates = connected.map { "\($0.udid) (\($0.name))" }.joined(separator: ", ")
        throw CliError("multiple connected devices found; specify --udid", "Candidates: \(candidates)")
    }
    return connected[0].udid
}

private func copyFromDevice(udid: String, bundleId: String, source: String, destination: String) throws {
    try xcrun([
        "devicectl", "device", "copy", "from",
        "--device", udid,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundleId,
        "--source", source,
        "--destination", destination,
    ])
}

/// Pull db/-wal/-shm from the device's app data container into the local cache
/// and return the db path. Pulls within DeviceCache.pullTTLMs reuse the previous snapshot unless `refresh` is set.
func resolveDeviceDbPath(bundleId: String, explicitUdid: String?, refresh: Bool) throws -> String {
    let udid = try resolveDeviceUdid(explicitUdid)
    let directory = (deviceCacheRoot() as NSString).appendingPathComponent("\(udid)/\(bundleId)")
    let dbPath = (directory as NSString).appendingPathComponent(DatabaseContract.fileName)

    let fileManager = FileManager.default
    if !refresh,
       let modified = (try? fileManager.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date,
       Date().timeIntervalSince(modified) * 1000 < DeviceCache.pullTTLMs {
        return dbPath
    }

    try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    // A stale -wal from a previous pull must never pair with a fresh db copy.
    for suffix in ["", "-wal", "-shm"] {
        try? fileManager.removeItem(atPath: dbPath + suffix)
    }

    do {
        try copyFromDevice(udid: udid, bundleId: bundleId, source: DatabaseContract.containerRelativePath, destination: dbPath)
    } catch let e as ProcessFailure {
        throw CliError(
            "failed to pull \(DatabaseContract.fileName) from device \(udid)\(e.stderr.isEmpty ? "" : ": \(e.stderr)")",
            "The app must be installed with a development signature and have run at least once (DEBUG build). Check the bundle id, or fall back to the manual export route (share Tokiwatari.exportSnapshot() output, then --db <path>)."
        )
    }
    // The SDK checkpoints with TRUNCATE, so -wal/-shm are usually absent.
    for suffix in ["-wal", "-shm"] {
        try? copyFromDevice(udid: udid, bundleId: bundleId, source: DatabaseContract.containerRelativePath + suffix, destination: dbPath + suffix)
    }

    // mtime = pull time, so the freshness check above works regardless of the file's original modification time on the device.
    try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: dbPath)
    pruneStaleDeviceCaches()
    return dbPath
}
