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

    /// - Parameter name: the display name for an app path.
    public static func adminRights(
        _ rows: [AdminRightAggregate],
        timeZone: TimeZone = .current,
        name: (_ path: String) -> String
    ) -> String {
        let timestamp = timestamps(in: timeZone)
        let lines = rows.map { row -> [String] in
            [
                row.day,
                name(row.app),
                row.app,
                row.client,
                row.rightName,
                row.right,
                String(row.count),
                timestamp(row.firstSeen),
                timestamp(row.lastSeen),
            ]
        }
        return CSV.document(
            header: ["day", "app", "app_path", "client_path", "admin_right", "right", "count", "first_seen", "last_seen"],
            rows: lines)
    }

    /// - Parameters:
    ///   - client: the display name for an `AIClient` ID.
    ///   - name: the display name for an identifier or path and the binary logged for it.
    public static func aiActivity(
        _ activities: [AIActivity],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        client: (String) -> String,
        name: (_ identifier: String, _ binaryPath: String) -> String
    ) -> String {
        let timestamp = timestamps(in: timeZone)
        let rows = activities.map { activity -> [String] in
            [
                timestamp(activity.start),
                activity.end.map { timestamp($0) } ?? "",
                client(activity.client),
                activity.kind.rawValue,
                activity.what,
                activity.detail,
                name(activity.app, activity.binaryPath),
                activity.app,
                activity.accessor,
                activity.binaryPath,
                activity.resultName ?? "",
                activity.preflight ? "yes" : "no",
                String(activity.count),
                activity.kind == .sensor ? seconds(activity.duration(now: now)) : "",
                activity.whileLocked ? "yes" : "no",
                activity.isFirstTime ? "yes" : "no",
                activity.isProbablyComputerUse ? "yes" : "no",
                activity.approximate ? "yes" : "no",
            ]
        }
        return CSV.document(
            header: ["start", "end", "client", "kind", "what", "detail", "app", "identifier", "accessor", "binary_path",
                     "result", "preflight", "count", "duration_s", "while_locked", "first_time", "probably_computer_use",
                     "approximate"],
            rows: rows)
    }
}
