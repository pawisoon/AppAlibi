import Foundation

/// One entry from `/usr/bin/log show|stream --style ndjson`.
public struct LogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let eventMessage: String
    public let processID: Int
    public let subsystem: String?
    public let category: String?

    public init(timestamp: Date, eventMessage: String, processID: Int, subsystem: String? = nil, category: String? = nil) {
        self.timestamp = timestamp
        self.eventMessage = eventMessage
        self.processID = processID
        self.subsystem = subsystem
        self.category = category
    }

    /// Parses one NDJSON line.
    ///
    /// Returns nil for anything that is not a log event: the plain-text header
    /// printed by `log stream`, the trailing `{"count":N,"finished":1}` object
    /// printed by `log show`, and malformed lines.
    public static func parse(_ line: some DataProtocol) -> LogEntry? {
        guard line.first == UInt8(ascii: "{") else { return nil }
        guard let raw = try? decoder.decode(RawEntry.self, from: Data(line)),
              let message = raw.eventMessage,
              let stamp = raw.timestamp,
              let date = LogTimestamp.parse(stamp)
        else { return nil }
        return LogEntry(
            timestamp: date,
            eventMessage: message,
            processID: raw.processID ?? 0,
            subsystem: raw.subsystem,
            category: raw.category
        )
    }

    public static func parse(_ line: String) -> LogEntry? {
        parse(Data(line.utf8))
    }

    private static let decoder = JSONDecoder()

    private struct RawEntry: Decodable {
        let timestamp: String?
        let eventMessage: String?
        let processID: Int?
        let subsystem: String?
        let category: String?
    }
}

/// Timestamps in `log` output: `2026-10-08 00:11:56.880495+0200`.
public enum LogTimestamp {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter
    }()

    public static func parse(_ string: String) -> Date? {
        guard let dot = string.firstIndex(of: ".") else {
            return formatter.date(from: string)
        }
        let base = string[..<dot]
        let rest = string[string.index(after: dot)...]
        guard let zoneStart = rest.firstIndex(where: { $0 == "+" || $0 == "-" }),
              let date = formatter.date(from: String(base + rest[zoneStart...])),
              let fraction = Double("0." + rest[..<zoneStart])
        else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// Format accepted by `log show --start`.
    public static func argument(for date: Date) -> String {
        formatter.string(from: date)
    }
}
