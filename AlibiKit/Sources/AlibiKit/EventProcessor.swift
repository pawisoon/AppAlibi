import Foundation

public enum CollectedEvent: Equatable, Sendable {
    case sensor(SensorEvent)
    case tcc(TCCAccessEvent)
    case screenLock(ScreenLockEvent)
    case adminRight(AdminRightEvent)
}

/// Pure transformation from log entries to domain events. No I/O.
public struct EventProcessor: Sendable {
    public var tracker: SessionTracker
    public var correlator = TCCCorrelator()
    /// loginwindow can announce the same state twice; only changes are events.
    public private(set) var screenLocked: Bool
    /// Rights every process gets without asking are not recorded. Replaceable in tests.
    public var isOpenRight: @Sendable (String) -> Bool = AdminRight.isOpenToEveryone

    public init(active: Set<Attribution> = [], screenLocked: Bool = false) {
        tracker = SessionTracker(active: active)
        self.screenLocked = screenLocked
    }

    public mutating func process(_ entry: LogEntry) -> [CollectedEvent] {
        if let snapshot = ControlCenterParser.snapshot(from: entry.eventMessage) {
            return tracker.apply(snapshot, at: entry.timestamp).map(CollectedEvent.sensor)
        }
        if let locked = ScreenLockParser.locked(from: entry.eventMessage) {
            guard locked != screenLocked else { return [] }
            screenLocked = locked
            return [.screenLock(ScreenLockEvent(locked: locked, date: entry.timestamp))]
        }
        if let right = AdminRightParser.event(from: entry) {
            return isOpenRight(right.right) ? [] : [.adminRight(right)]
        }
        return correlator.consume(entry).map(CollectedEvent.tcc)
    }
}
