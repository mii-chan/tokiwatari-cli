import ArgumentParser
import Foundation

/// Global CLI flags shared by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("bundle-id"), help: "app bundle identifier")
    var bundleId: String?

    @Option(help: "simulator or device UDID")
    var udid: String?

    @Option(help: "read this SQLite file directly, bypassing simulator resolution")
    var db: String?

    @Option(help: "data source: simulator (default) | device")
    var source: String?

    @Flag(help: "force a fresh device pull")
    var refresh = false

    @Flag(help: "output the JSON envelope")
    var json = false
}

struct ProjectConfig {
    static let fileName = ".tokiwatari.json"

    var bundleId: String?
    var udid: String?
    var source: String?
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func environment(_ name: String) -> String? {
    nonEmpty(ProcessInfo.processInfo.environment[name])
}

/// Read ./.tokiwatari.json from the current working directory (missing file is fine).
func loadProjectConfig() throws -> ProjectConfig {
    let file = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(ProjectConfig.fileName)
    guard FileManager.default.fileExists(atPath: file) else { return ProjectConfig() }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProjectConfig()
        }
        return ProjectConfig(
            bundleId: nonEmpty(parsed["bundleId"] as? String),
            udid: nonEmpty(parsed["udid"] as? String),
            source: nonEmpty(parsed["source"] as? String)
        )
    } catch {
        throw CliError(
            "failed to parse \(file): \(error.localizedDescription)",
            #"Fix the JSON, e.g. { "bundleId": "<bundle identifier>", "udid": null, "source": "simulator" }"#
        )
    }
}

/// Resolution order: flag > environment variable > .tokiwatari.json > auto detection.
func resolveBundleId(_ opts: GlobalOptions) throws -> String? {
    if let value = nonEmpty(opts.bundleId) { return value }
    if let value = environment("TOKIWATARI_BUNDLE_ID") { return value }
    return try loadProjectConfig().bundleId
}

func resolveConfiguredUdid(_ opts: GlobalOptions) throws -> String? {
    if let value = nonEmpty(opts.udid) { return value }
    if let value = environment("TOKIWATARI_UDID") { return value }
    return try loadProjectConfig().udid
}

func resolveSource(_ opts: GlobalOptions) throws -> String {
    let source = try nonEmpty(opts.source)
        ?? environment("TOKIWATARI_SOURCE")
        ?? loadProjectConfig().source
        ?? "simulator"
    guard source == "simulator" || source == "device" else {
        throw CliError(
            "invalid source: \(source)",
            "Use \"simulator\" or \"device\" (--source / TOKIWATARI_SOURCE / the \"source\" key in \(ProjectConfig.fileName))."
        )
    }
    return source
}

/// Resolve the SQLite file path to open (--db bypasses source resolution entirely).
func resolveDbPath(_ opts: GlobalOptions) throws -> String {
    if let db = nonEmpty(opts.db) { return db }

    guard let bundleId = try resolveBundleId(opts) else {
        throw CliError(
            "bundle id is not configured",
            "Pass --bundle-id <id>, set TOKIWATARI_BUNDLE_ID, or create \(ProjectConfig.fileName) with { \"bundleId\": \"<bundle identifier>\" }. You can also point directly at a file with --db <path>."
        )
    }
    let udid = try resolveConfiguredUdid(opts)
    if try resolveSource(opts) == "device" {
        return try resolveDeviceDbPath(bundleId: bundleId, explicitUdid: udid, refresh: opts.refresh)
    }
    return try resolveSimulatorDbPath(bundleId: bundleId, explicitUdid: udid)
}
