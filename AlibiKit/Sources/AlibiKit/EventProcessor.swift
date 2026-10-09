import Foundation

public enum CollectedEvent: Equatable, Sendable {
    case sensor(SensorEvent)
    case tcc(TCCAccessEvent)
}

/// Pure transformation from log entries to domain events. No I/O.
public struct EventProcessor: Sendable {
    public var tracker: SessionTracker
    public var correlator = TCCCorrelator()

    public init(active: Set<Attribution> = []) {
        tracker = SessionTracker(active: active)
    }

    public mutating func process(_ entry: LogEntry) -> [CollectedEvent] {
        if let snapshot = ControlCenterParser.snapshot(from: entry.eventMessage) {
            return tracker.apply(snapshot, at: entry.timestamp).map(CollectedEvent.sensor)
        }
        return correlator.consume(entry).map(CollectedEvent.tcc)
    }
}
