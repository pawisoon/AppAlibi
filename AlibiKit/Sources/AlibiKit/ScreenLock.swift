import Darwin
import Foundation

/// The screen locked or unlocked.
public struct ScreenLockEvent: Equatable, Sendable {
    public let locked: Bool
    public let date: Date

    public init(locked: Bool, date: Date) {
        self.locked = locked
        self.date = date
    }
}

public enum ScreenLockParser {
    /// Parses loginwindow's
    /// `-[SessionAgentNotificationCenter sendDistributedNotification:object:] | sendDistributedNotification: com.apple.screenIsLocked, with object:501`.
    /// Returns true for locked, false for unlocked, nil for any other line or
    /// another user's session (Fast User Switching runs one loginwindow per user).
    public static func locked(from message: String, userID: uid_t = getuid()) -> Bool? {
        guard let marker = message.range(of: LogPredicates.screenLockMarker) else { return nil }
        let rest = message[marker.upperBound...]
        let name = String(rest.prefix { $0 != "," })
        let locked: Bool
        switch name {
        case LogPredicates.screenLockedName: locked = true
        case LogPredicates.screenUnlockedName: locked = false
        default: return nil
        }
        if let object = rest.range(of: "with object:") {
            let value = rest[object.upperBound...].prefix(while: \.isNumber)
            if let owner = uid_t(value), owner != userID { return nil }
        }
        return locked
    }
}

/// Times the screen was locked, for marking what happened while nobody was looking.
public struct ScreenLockSpans: Sendable, Equatable {
    /// Sorted, not overlapping. An open lock ends at the `now` it was read with.
    public let spans: [DateInterval]

    /// Use that overlaps a lock by less than this is an app noticing the lock
    /// and letting go, or one starting as the user unlocks.
    public static let minimumOverlap: TimeInterval = 5

    public init(_ spans: [DateInterval]) {
        self.spans = ActivityReport.merge(spans)
    }

    /// How much of the interval fell inside a lock.
    public func overlap(with interval: DateInterval) -> TimeInterval {
        spans.reduce(0) { total, span in
            total + (span.intersection(with: interval)?.duration ?? 0)
        }
    }

    /// Whether the moment fell inside a lock.
    public func contains(_ date: Date) -> Bool {
        spans.contains { $0.start < date && date < $0.end }
    }
}

public enum SystemClock {
    /// When the Mac last started. A lock still open from before then ended when the Mac shut down.
    public static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
