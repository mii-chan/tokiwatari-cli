import ArgumentParser
import Foundation
import GRDB

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "diagnose xcrun, container resolution, database, schema version, and WAL state"
    )
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runReporting(global) {
            var checks: [(name: String, ok: Bool, detail: String)] = []
            func add(_ name: String, _ ok: Bool, _ detail: String) {
                checks.append((name, ok, detail))
            }
            let fileManager = FileManager.default

            // 1. xcrun / simctl (skipped when --db bypasses the data source)
            if global.db != nil {
                add("xcrun", true, "skipped (--db specified)")
            } else if xcrunAvailable() {
                add("xcrun", true, "xcrun found")
            } else {
                add("xcrun", false, "xcrun not found — is Xcode (or Command Line Tools) installed?")
            }

            // 2. configuration
            let bundleId = (try? resolveBundleId(global)) ?? nil
            let udid = (try? resolveConfiguredUdid(global)) ?? nil
            var source: String?
            var sourceError: String?
            do {
                source = try resolveSource(global)
            } catch let e as CliError {
                sourceError = e.message
            }
            let configFileExists = fileManager.fileExists(
                atPath: (fileManager.currentDirectoryPath as NSString).appendingPathComponent(ProjectConfig.fileName)
            )
            add(
                "config",
                sourceError == nil,
                "source=\(source ?? "INVALID (\(sourceError ?? ""))") bundleId=\(bundleId ?? "(unset)") udid=\(udid ?? "(auto)") \(ProjectConfig.fileName)=\(configFileExists ? "present" : "absent")\(global.db.map { " db=\($0)" } ?? "")"
            )

            // 3. db path resolution
            var dbPath: String?
            if let db = global.db {
                dbPath = db
                add("db path", true, db)
            } else if bundleId == nil {
                add("db path", false, "bundle id not configured (--bundle-id / TOKIWATARI_BUNDLE_ID / \(ProjectConfig.fileName))")
            } else if source == "device" {
                do {
                    let path = try resolveDeviceDbPath(bundleId: bundleId!, explicitUdid: udid, refresh: true)
                    dbPath = path
                    add("db path", true, "\(path) (pulled from device)")
                } catch let e as CliError {
                    add("db path", false, "\(e.message)\(e.hint.map { " — \($0)" } ?? "")")
                    if let connected = try? listConnectedDevices() {
                        add(
                            "connected devices",
                            !connected.isEmpty,
                            connected.isEmpty ? "none" : connected.map { "\($0.udid) (\($0.name))" }.joined(separator: ", ")
                        )
                    }
                }
            } else if source == "simulator" {
                do {
                    let resolvedUdid = try resolveUdid(udid)
                    let container = try getAppContainer(udid: resolvedUdid, bundleId: bundleId!)
                    let path = (container as NSString)
                        .appendingPathComponent(DatabaseContract.containerRelativePath)
                    dbPath = path
                    add("db path", true, "\(path) (udid=\(resolvedUdid))")
                } catch let e as CliError {
                    add("db path", false, "\(e.message)\(e.hint.map { " — \($0)" } ?? "")")
                    if let booted = try? listBootedSimulators() {
                        add(
                            "booted simulators",
                            !booted.isEmpty,
                            booted.isEmpty ? "none" : booted.map { "\($0.udid) (\($0.name))" }.joined(separator: ", ")
                        )
                    }
                }
            }

            // 4+. database file, open, user_version, counts, WAL
            if let dbPath {
                if !fileManager.fileExists(atPath: dbPath) {
                    add("db file", false, "not found: \(dbPath)")
                } else {
                    let size = (try? fileManager.attributesOfItem(atPath: dbPath))?[.size] as? Int64 ?? 0
                    add("db file", true, "\(dbPath) (\(size) bytes)")

                    let walPath = dbPath + "-wal"
                    let shmPath = dbPath + "-shm"
                    let walDetail: String
                    if fileManager.fileExists(atPath: walPath) {
                        let walSize = (try? fileManager.attributesOfItem(atPath: walPath))?[.size] as? Int64 ?? 0
                        walDetail = "-wal present (\(walSize) bytes)"
                    } else {
                        walDetail = "-wal absent"
                    }
                    let shmDetail = fileManager.fileExists(atPath: shmPath) ? "-shm present" : "-shm absent"
                    add("wal", true, "\(walDetail), \(shmDetail)")

                    do {
                        let opened = try openDatabase(dbPath)
                        defer { try? opened.queue.close() }
                        add(
                            "open readonly",
                            true,
                            opened.snapshotPath.map { "opened via snapshot fallback (\($0))" } ?? "opened directly"
                        )
                        let actualVersion = try opened.queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
                        add(
                            "user_version",
                            actualVersion == DatabaseContract.expectedUserVersion,
                            "expected \(DatabaseContract.expectedUserVersion), found \(actualVersion)"
                        )
                        if actualVersion == DatabaseContract.expectedUserVersion {
                            do {
                                let counts = try opened.queue.read { db in
                                    try Row.fetchOne(
                                        db,
                                        sql: "SELECT COUNT(*) AS events, COUNT(DISTINCT session_id) AS sessions FROM events"
                                    )
                                }
                                let events: Int64 = counts?["events"] ?? 0
                                let sessions: Int64 = counts?["sessions"] ?? 0
                                add("events", true, "\(events) events in \(sessions) sessions")
                            } catch {
                                add("events", false, "failed to read events table: \(error)")
                            }
                        }
                    } catch let e as CliError {
                        add("open readonly", false, e.message)
                    }
                }
            }

            let allOk = checks.allSatisfy(\.ok)

            if global.json {
                let data: [String: Any] = [
                    "ok": allOk,
                    "checks": checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] },
                ]
                printSuccess(json: true, data: data) { "" }
            } else {
                let nameWidth = checks.map(\.name.count).max() ?? 0
                var lines = checks.map { "\($0.ok ? "ok  " : "FAIL")  \(padEnd($0.name, nameWidth))  \($0.detail)" }
                lines.append(allOk ? "all checks passed" : "some checks FAILED")
                print(lines.joined(separator: "\n"))
            }
            if !allOk { throw ExitCode(1) }
        }
    }
}
