import Foundation

/// Timestamps are stored by GRDB as "yyyy-MM-dd HH:mm:ss.SSS" UTC strings, so
/// string comparison is consistent with chronological comparison. Compact text
/// output displays local time; stored values and --json output stay UTC.
enum GrdbTime {

    /// Honors the TZ environment variable explicitly so tests are
    /// machine-independent; falls back to the system timezone.
    static var displayTimeZone: TimeZone {
        if let tz = ProcessInfo.processInfo.environment["TZ"], let zone = TimeZone(identifier: tz) {
            return zone
        }
        return .current
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Parse a GRDB timestamp string (UTC).
    static func parseGrdbTimestamp(_ ts: String) -> Date? {
        formatter("yyyy-MM-dd HH:mm:ss.SSS", timeZone: TimeZone(identifier: "UTC")!).date(from: ts)
    }

    /// Format a Date as a GRDB "yyyy-MM-dd HH:mm:ss.SSS" UTC string.
    static func formatGrdbTimestamp(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss.SSS", timeZone: TimeZone(identifier: "UTC")!).string(from: date)
    }

    /// Stored UTC timestamp -> local "yyyy-MM-dd HH:mm:ss" (text display only).
    static func localDateTime(_ ts: String) -> String {
        guard let date = parseGrdbTimestamp(ts) else { return ts }
        return formatter("yyyy-MM-dd HH:mm:ss", timeZone: displayTimeZone).string(from: date)
    }

    /// Stored UTC timestamp -> local "yyyy-MM-dd HH:mm:ss.SSS +09:00" (show detail).
    static func localTimestampWithOffset(_ ts: String) -> String {
        guard let date = parseGrdbTimestamp(ts) else { return ts }
        let zone = displayTimeZone
        let local = formatter("yyyy-MM-dd HH:mm:ss.SSS", timeZone: zone).string(from: date)
        let offsetMinutes = zone.secondsFromGMT(for: date) / 60
        let sign = offsetMinutes < 0 ? "-" : "+"
        let absMinutes = abs(offsetMinutes)
        return String(format: "%@ %@%02d:%02d", local, sign, absMinutes / 60, absMinutes % 60)
    }

    /// Stored UTC timestamp -> local "HH:mm:ss.SSS" (compact per-row display).
    static func timeOfDay(_ ts: String) -> String {
        guard let date = parseGrdbTimestamp(ts) else { return ts }
        return formatter("HH:mm:ss.SSS", timeZone: displayTimeZone).string(from: date)
    }
}
