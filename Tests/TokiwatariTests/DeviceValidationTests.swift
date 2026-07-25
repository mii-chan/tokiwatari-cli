import Foundation
import Testing
@testable import TokiwatariCore

struct DeviceValidationTests {

    // MARK: - in-process validator behavior

    @Test func validatorsAcceptTypicalValues() throws {
        #expect(try validatedDeviceBundleId("com.example.app") == "com.example.app")
        #expect(try validatedDeviceBundleId("a") == "a")
        #expect(try validatedDeviceBundleId("com.example.my-app2") == "com.example.my-app2")
        #expect(try validatedDeviceUdid("00008120-001A2B3C4D5E6F7A") == "00008120-001A2B3C4D5E6F7A")
    }

    @Test func validatorsRejectTraversalAndReservedNames() {
        for bundleId in ["", ".", "..", "../evil", ".staging-x", "a/b", "com.example.app.", "-leading", String(repeating: "a", count: 256)] {
            #expect(throws: CliError.self) { try validatedDeviceBundleId(bundleId) }
        }
        for udid in ["", "../../x", "a/b", "a.b", String(repeating: "a", count: 129)] {
            #expect(throws: CliError.self) { try validatedDeviceUdid(udid) }
        }
    }

    // MARK: - CLI behavior (validation must fire before devicectl runs)

    @Test func traversalUdidFailsBeforeDevicectl() throws {
        let result = try run(["sessions", "--source", "device", "--bundle-id", "com.example.app", "--udid=../../x"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("invalid device udid"))
    }

    @Test func traversalBundleIdFailsBeforeDevicectl() throws {
        let result = try run(["sessions", "--source", "device", "--bundle-id", "../evil"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("invalid bundle id"))
    }

    @Test func reservedPrefixBundleIdFails() throws {
        let result = try run(["sessions", "--source", "device", "--bundle-id", ".staging-x"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("invalid bundle id"))
    }

    @Test func overlongBundleIdFails() throws {
        let result = try run(["sessions", "--source", "device", "--bundle-id", String(repeating: "a", count: 256)])
        #expect(result.status == 1)
        #expect(result.stderr.contains("invalid bundle id"))
    }

    @Test func maliciousProjectConfigIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = #"{"bundleId": "../evil", "source": "device"}"#
        try config.write(to: dir.appendingPathComponent(".tokiwatari.json"), atomically: true, encoding: .utf8)

        let result = try run(["sessions"], currentDirectory: dir.path)
        #expect(result.status == 1)
        #expect(result.stderr.contains("invalid bundle id"))
    }
}
