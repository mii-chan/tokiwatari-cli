import Foundation

/// JSON text rendering that matches Node's `JSON.stringify(value, null, 2)`
/// formatting (`"key": value`, 2-space indent, no slash escaping), with object keys sorted — used for display only.
enum JSONText {

    static func prettySorted(_ value: Any) -> String {
        render(value, depth: 0)
    }

    /// Parse-then-pretty-print for body strings; non-JSON text passes through.
    static func prettyJsonish(_ text: String) -> String {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return text
        }
        return render(parsed, depth: 0)
    }

    private static func render(_ value: Any, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth + 1)
        let closePad = String(repeating: "  ", count: depth)
        switch value {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { return "{}" }
            let body = dictionary.keys.sorted()
                .map { "\(pad)\(escaped($0)): \(render(dictionary[$0]!, depth: depth + 1))" }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(closePad)}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            let body = array.map { "\(pad)\(render($0, depth: depth + 1))" }.joined(separator: ",\n")
            return "[\n\(body)\n\(closePad)]"
        case let string as String:
            return escaped(string)
        case let number as NSNumber:
            return rendered(number)
        case is NSNull:
            return "null"
        default:
            return escaped(String(describing: value))
        }
    }

    static func rendered(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let objCType = String(cString: number.objCType)
        if objCType == "d" || objCType == "f" {
            let double = number.doubleValue
            // Match JS: integral doubles print without a decimal point.
            if double.truncatingRemainder(dividingBy: 1) == 0, abs(double) < 1e15 {
                return String(Int64(double))
            }
            return "\(double)"
        }
        return "\(number.int64Value)"
    }

    static func escaped(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
