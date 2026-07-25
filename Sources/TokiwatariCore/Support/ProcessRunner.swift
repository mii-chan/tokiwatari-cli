import Foundation

struct ProcessFailure: Error {
    let message: String
    let stderr: String
}

/// Run `xcrun <arguments>` and return trimmed stdout; throws on nonzero exit.
@discardableResult
func xcrun(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw ProcessFailure(message: String(describing: error), stderr: "")
    }
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ProcessFailure(
            message: "xcrun \(arguments.prefix(2).joined(separator: " ")) exited with status \(process.terminationStatus)",
            stderr: errText
        )
    }
    return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func xcrunAvailable() -> Bool {
    (try? xcrun(["--version"])) != nil
}
