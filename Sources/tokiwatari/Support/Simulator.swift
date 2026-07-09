import Foundation

struct BootedSimulator {
    let udid: String
    let name: String
}

private enum PathCache {
    /// paths.json entry cap; the format has no recency info, so overflow resets the cache.
    static let maxEntries = 20
}

private func cacheFilePath() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".cache/tokiwatari/paths.json")
}

private func loadPathCache() -> [String: String] {
    guard let data = FileManager.default.contents(atPath: cacheFilePath()),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return parsed
}

private func savePathCache(_ cache: [String: String]) {
    // Cache is best-effort; never fail a command because of it.
    let file = cacheFilePath()
    try? FileManager.default.createDirectory(
        atPath: (file as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    if let data = try? JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: file))
    }
}

func listBootedSimulators() throws -> [BootedSimulator] {
    let out: String
    do {
        out = try xcrun(["simctl", "list", "devices", "booted", "-j"])
    } catch let e as ProcessFailure {
        throw CliError(
            "failed to run simctl: \(e.stderr.isEmpty ? e.message : e.stderr)",
            "Is Xcode installed? Try `xcrun simctl list`. You can bypass simulator resolution with --db <path>."
        )
    }
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
          let devices = parsed["devices"] as? [String: [[String: Any]]]
    else { return [] }
    var booted: [BootedSimulator] = []
    for runtimeDevices in devices.values {
        for device in runtimeDevices where device["state"] as? String == "Booted" {
            if let udid = device["udid"] as? String, let name = device["name"] as? String {
                booted.append(BootedSimulator(udid: udid, name: name))
            }
        }
    }
    return booted
}

/// Pick the target simulator UDID: explicit udid, or the single booted simulator.
func resolveUdid(_ explicitUdid: String?) throws -> String {
    if let explicitUdid { return explicitUdid }
    let booted = try listBootedSimulators()
    if booted.isEmpty {
        throw CliError(
            "no booted simulator found",
            "Boot a simulator (open Simulator.app or `xcrun simctl boot <udid>`), pass --udid <udid>, or bypass with --db <path>."
        )
    }
    if booted.count > 1 {
        let candidates = booted.map { "\($0.udid) (\($0.name))" }.joined(separator: ", ")
        throw CliError("multiple booted simulators found; specify --udid", "Candidates: \(candidates)")
    }
    return booted[0].udid
}

func getAppContainer(udid: String, bundleId: String) throws -> String {
    do {
        return try xcrun(["simctl", "get_app_container", udid, bundleId, "data"])
    } catch let e as ProcessFailure {
        throw CliError(
            "failed to resolve app container for \(bundleId) on \(udid)\(e.stderr.isEmpty ? "" : ": \(e.stderr)")",
            "Check that the app is installed on that simulator and the bundle id is correct (--bundle-id / TOKIWATARI_BUNDLE_ID / .tokiwatari.json). You can bypass with --db <path>."
        )
    }
}

/// Resolve the db path for (bundleId, udid). Container paths are stable while
/// the simulator is booted, so results are cached until the file disappears.
func resolveSimulatorDbPath(bundleId: String, explicitUdid: String?) throws -> String {
    let udid = try resolveUdid(explicitUdid)
    let cacheKey = "\(udid):\(bundleId)"
    var cache = loadPathCache()
    if let cached = cache[cacheKey], FileManager.default.fileExists(atPath: cached) {
        return cached
    }

    let container = try getAppContainer(udid: udid, bundleId: bundleId)
    let dbPath = (container as NSString).appendingPathComponent(DatabaseContract.containerRelativePath)
    if cache.count >= PathCache.maxEntries {
        cache = [:]
    }
    cache[cacheKey] = dbPath
    savePathCache(cache)
    return dbPath
}
