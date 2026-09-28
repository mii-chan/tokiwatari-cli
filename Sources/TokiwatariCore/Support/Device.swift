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

private func deviceCacheStore() -> DeviceCacheStore {
    DeviceCacheStore(root: URL(
        fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".cache/tokiwatari/device"),
        isDirectory: true
    ))
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

private func isAsciiAlphanumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
}

/// Path-safe subset of the characters commonly used in CFBundleIdentifier;
/// the bundle id becomes a cache directory name, so anything else is rejected.
func validatedDeviceBundleId(_ value: String) throws -> String {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 255,
          isAsciiAlphanumeric(bytes.first!), isAsciiAlphanumeric(bytes.last!),
          bytes.allSatisfy({ isAsciiAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") })
    else {
        throw CliError(
            "invalid bundle id: \(value)",
            "Bundle ids must be 1-255 bytes of ASCII letters, digits, '.' or '-', starting and ending with a letter or digit. Check --bundle-id / TOKIWATARI_BUNDLE_ID / .tokiwatari.json."
        )
    }
    return value
}

func validatedDeviceUdid(_ value: String) throws -> String {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 128,
          bytes.allSatisfy({ isAsciiAlphanumeric($0) || $0 == UInt8(ascii: "-") })
    else {
        throw CliError(
            "invalid device udid: \(value)",
            "UDIDs must be 1-128 bytes of ASCII letters, digits or '-'. Check --udid / TOKIWATARI_UDID / .tokiwatari.json, or run `xcrun devicectl list devices`."
        )
    }
    return value
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
    let bundleId = try validatedDeviceBundleId(bundleId)
    if let explicitUdid { _ = try validatedDeviceUdid(explicitUdid) }
    let udid = try validatedDeviceUdid(resolveDeviceUdid(explicitUdid))

    return try deviceCacheStore().resolveDbPath(
        udid: udid,
        bundleId: bundleId,
        refresh: refresh,
        reuseWithinMs: DeviceCache.pullTTLMs,
        pruneOlderThanMs: DeviceCache.pruneTTLMs
    ) { stagingPath in
        let stagingDb = (stagingPath as NSString).appendingPathComponent(DatabaseContract.fileName)
        do {
            try copyFromDevice(udid: udid, bundleId: bundleId, source: DatabaseContract.containerRelativePath, destination: stagingDb)
        } catch let e as ProcessFailure {
            throw CliError(
                "failed to pull \(DatabaseContract.fileName) from device \(udid)\(e.stderr.isEmpty ? "" : ": \(e.stderr)")",
                "The app must be installed with a development signature and have run at least once with the Tokiwatari SDK configured. Check the bundle id, or fall back to the manual export route (share Tokiwatari.exportSnapshot() output, then --db <path>)."
            )
        }
        // The SDK checkpoints with TRUNCATE, so -wal/-shm are usually absent. A copy
        // failure is indistinguishable from "absent on the device" (devicectl stderr
        // classification is fragile), so snapshot validation is the only publish gate —
        // a consistent but slightly older snapshot may be published.
        for suffix in ["-wal", "-shm"] {
            do {
                try copyFromDevice(udid: udid, bundleId: bundleId, source: DatabaseContract.containerRelativePath + suffix, destination: stagingDb + suffix)
            } catch {
                try? FileManager.default.removeItem(atPath: stagingDb + suffix)
            }
        }
    }
}
