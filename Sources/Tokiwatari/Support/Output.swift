import Foundation

func padEnd(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// One-line summary per event. The api subject prefers the identifier over the
/// URL path (for GraphQL rows the path is a constant /graphql and carries no information).
func summarizeEvent(_ row: EventRow) -> String {
    guard row.eventKind == "api" else {
        return row.identifier ?? ""
    }
    var subject = row.identifier ?? ""
    if subject.isEmpty, let url = row.url {
        if let components = URLComponents(string: url), !components.path.isEmpty {
            subject = components.path
        } else {
            subject = url
        }
    }
    var parts = [row.httpMethod ?? "?", subject]
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

/// A GraphQL request body ({"query": "...", ...}); nil for anything else.
private func parseGraphQLBody(_ body: Any?) -> (query: String, variables: [String: Any]?)? {
    guard let body = body as? String,
          let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
          let query = parsed["query"] as? String
    else { return nil }
    return (query, parsed["variables"] as? [String: Any])
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
            if let body = part["body"], !(body is NSNull) {
                let truncated = (part["body_truncated"] as? Bool == true) ? " (truncated at 64KB)" : ""
                if title == "request", let gql = parseGraphQLBody(body) {
                    // The query arrives as a JSON string ("\n"-escaped); unfold it.
                    lines.append("\(title) body (GraphQL)\(truncated):")
                    lines.append(indent(gql.query.trimmingCharacters(in: .whitespacesAndNewlines)))
                    if let variables = gql.variables, !variables.isEmpty {
                        lines.append("variables:")
                        lines.append(indent(JSONText.prettySorted(variables)))
                    }
                } else {
                    lines.append("\(title) body\(truncated):")
                    lines.append(indent(JSONText.prettyJsonish(stringified(body))))
                }
            }
        }
        section("request", payload?["request"])
        section("response", payload?["response"])
        if let error = payload?["error"], !(error is NSNull) {
            lines.append("error     \(stringified(error))")
        }
    } else {
        lines.append("identifier \(row.identifier ?? "")")
        if let payload, !payload.isEmpty {
            lines.append("parameters:")
            lines.append(indent(JSONText.prettySorted(payload)))
        }
    }
    return lines.joined(separator: "\n")
}

private func stringified(_ value: Any) -> String {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return JSONText.rendered(number) }
    return String(describing: value)
}
