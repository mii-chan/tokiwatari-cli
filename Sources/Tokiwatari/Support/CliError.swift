import Foundation

/// Error carrying a self-repair hint for the agent (mapped to the `hint` field of the JSON envelope).
struct CliError: Error {
    let message: String
    let hint: String?

    init(_ message: String, _ hint: String? = nil) {
        self.message = message
        self.hint = hint
    }
}

// --json output: success prints the data value as-is; failure prints {error, hint?} and exits 1.

func printSuccess(json: Bool, data: Any, text: () -> String) {
    if json {
        print(compactJSON(data))
    } else {
        print(sanitizedForTerminal(text()))
    }
}

func printFailure(json: Bool, error: any Error) {
    let (message, hint): (String, String?) = {
        if let cliError = error as? CliError { return (cliError.message, cliError.hint) }
        return (String(describing: error), nil)
    }()
    if json {
        var envelope: [String: Any] = ["error": message]
        if let hint { envelope["hint"] = hint }
        print(compactJSON(envelope))
    } else {
        var text = "error: \(sanitizedForTerminal(message))\n"
        if let hint { text += "hint: \(sanitizedForTerminal(hint))\n" }
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Escape control characters (except structural \n and \t) so recorded content
/// cannot drive the terminal. --json needs nothing: JSON encoding escapes them.
func sanitizedForTerminal(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: needsTerminalEscape) else { return text }
    var out = ""
    for scalar in text.unicodeScalars {
        if needsTerminalEscape(scalar) {
            out += String(format: "\\u%04x", scalar.value)
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// C0 controls (minus \t \n), DEL, and C1 controls (0x9B is a one-byte CSI).
private func needsTerminalEscape(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A: return false
    case 0x00...0x1F, 0x7F, 0x80...0x9F: return true
    default: return false
    }
}

/// Single-line JSON (used for the --json envelope).
func compactJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    else { return "null" }
    return String(decoding: data, as: UTF8.self)
}
