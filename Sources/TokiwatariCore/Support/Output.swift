import Foundation

func padEnd(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// One-line summary per event: an api row shows its app-supplied identifier
/// verbatim when present, otherwise "<method> <URL path>".
func summarizeEvent(_ row: EventRow) -> String {
    guard row.eventKind == "api" else {
        return row.identifier ?? ""
    }
    var parts: [String]
    if let identifier = row.identifier, !identifier.isEmpty {
        parts = [identifier]
    } else {
        var subject = row.url ?? ""
        if let components = URLComponents(string: subject), !components.path.isEmpty {
            subject = components.path
        }
        parts = [row.httpMethod ?? "?", subject]
    }
    if let statusCode = row.statusCode { parts.append(String(statusCode)) }
    if let durationMs = row.durationMs { parts.append("\(durationMs)ms") }
    return parts.joined(separator: " ")
}

func renderEventLines(_ rows: [EventRow]) -> String {
    if rows.isEmpty { return "(no events)" }
    let seqWidth = max(3, rows.map { String($0.sessionSequence).count }.max() ?? 0)
    var lines = ["\(padEnd("seq", seqWidth))  time          kind  summary"]
    for row in rows {
        lines.append(
            "\(padEnd(String(row.sessionSequence), seqWidth))  \(GrdbTime.timeOfDay(row.timestamp))  \(padEnd(row.eventKind, 4))  \(summarizeEvent(row))"
        )
    }
    return lines.joined(separator: "\n")
}

/// Times are local; the stored/--json values stay UTC.
func renderSessionHeader(sessionId: String, count: Int64, start: String, end: String) -> String {
    let startLocal = GrdbTime.localDateTime(start)
    let endLocal = GrdbTime.localDateTime(end)
    let endShort = endLocal.prefix(10) == startLocal.prefix(10) ? String(endLocal.dropFirst(11)) : endLocal
    return "session \(sessionId)  \(count) events  \(startLocal) ~ \(endShort)"
}

private func indent(_ text: String, pad: String = "  ") -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { pad + $0 }
        .joined(separator: "\n")
}

/// JSONSerialization output with the `" : "` key separator tightened to `": "`
/// (line-anchored, so string values are untouched).
private func prettyJSON(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
    ) else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: #"(?m)^(\s*"(?:[^"\\]|\\.)*") : "#, with: "$1: ", options: .regularExpression)
}

func renderEventDetail(_ row: EventRow, payload: [String: Any]?) -> String {
    var lines = [
        "session   \(row.sessionId)",
        "seq       \(row.sessionSequence)",
        "time      \(GrdbTime.localTimestampWithOffset(row.timestamp))",
        "kind      \(row.eventKind)",
    ]
    if row.eventKind == "api" {
        lines.append("call      \(summarizeEvent(row))")
        lines.append("url       \(row.url ?? "")")
        func section(_ title: String, _ part: Any?) {
            guard let part = part as? [String: Any] else { return }
            if let headers = part["headers"] as? [String: Any], !headers.isEmpty {
                lines.append("\(title) headers:")
                for name in headers.keys.sorted() {
                    lines.append("  \(name): \(headers[name] ?? "")")
                }
            }
            if let body = part["body"] {
                lines.append("\(title) body:")
                lines.append(indent(prettyJSON(body)))
            }
        }
        section("request", payload?["request"])
        section("response", payload?["response"])
        if let error = payload?["error"], !(error is NSNull) {
            lines.append("error:")
            lines.append(indent(prettyJSON(error)))
        }
        if let payload {
            let renderedKeys: Set<String> = ["request", "response", "error"]
            let metadata = payload.filter { !renderedKeys.contains($0.key) }
            if !metadata.isEmpty {
                lines.append("payload:")
                lines.append(indent(prettyJSON(metadata)))
            }
        }
    } else {
        lines.append("identifier \(row.identifier ?? "")")
        if let payload, !payload.isEmpty {
            lines.append("parameters:")
            lines.append(indent(prettyJSON(payload)))
        }
    }
    return lines.joined(separator: "\n")
}
