import Foundation

/// RFC 4180 CSV: comma separated, CRLF line ends, fields with a comma, quote or
/// line break wrapped in quotes.
public enum CSV {
    public static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// App names and bundle IDs come from whoever built the app. A cell that
    /// starts like a formula (`=HYPERLINK(...)`) runs as one in Excel or Numbers,
    /// so it gets a leading apostrophe, which spreadsheets read as "text".
    static func field(_ value: String) -> String {
        var value = value
        if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The history tables as CSV.
public enum CSVExport {
    /// `2026-10-09T08:46:09+02:00`, in the Mac's time zone.
    static func timestamps(in timeZone: TimeZone) -> (Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from:)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(Int(interval.rounded()))
    }

    /// - Parameter name: the display name for an identifier. The app side knows where bundles live.
    public static func sessions(
        _ sessions: [SensorSession],
        locks: ScreenLockSpans = ScreenLockSpans([]),
        now: Date = Date(),
        timeZone: TimeZone = .current,
        name: (String) -> String
    ) -> String {
        let timestamp = timestamps(in: timeZone)
        let rows = sessions.map { session -> [String] in
            let interval = DateInterval(start: session.startedAt, end: max(session.endedAt ?? now, session.startedAt))
            return [
                name(session.app),
                session.app,
                session.sensor.displayName,
                timestamp(session.startedAt),
                session.endedAt.map { timestamp($0) } ?? "",
                seconds(session.duration(now: now)),
                seconds(locks.overlap(with: interval)),
            ]
        }
        return CSV.document(
            header: ["app", "identifier", "sensor", "started", "ended", "duration_s", "while_locked_s"],
            rows: rows)
    }

    /// - Parameter name: the display name for an identifier and the binary tccd logged for it.
    public static func permissions(
        _ rows: [TCCAggregate],
        timeZone: TimeZone = .current,
        name: (_ identifier: String, _ binaryPath: String) -> String
    ) -> String {
        let timestamp = timestamps(in: timeZone)
        let lines = rows.map { row -> [String] in
            [
                row.day,
                name(row.app, row.binaryPath),
                row.app,
                row.accessor,
                row.binaryPath,
                row.serviceName,
                row.service,
                row.resultName,
                row.preflight ? "yes" : "no",
                String(row.count),
                timestamp(row.firstSeen),
                timestamp(row.lastSeen),
            ]
        }
        return CSV.document(
            header: ["day", "app", "identifier", "accessor", "binary_path", "permission", "service",
                     "result", "preflight", "count", "first_seen", "last_seen"],
            rows: lines)
    }
}
