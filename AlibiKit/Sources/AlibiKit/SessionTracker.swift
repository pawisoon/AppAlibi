import Foundation

public struct SensorEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case started, ended }
    public let kind: Kind
    public let attribution: Attribution
    public let date: Date

    public init(kind: Kind, attribution: Attribution, date: Date) {
        self.kind = kind
        self.attribution = attribution
        self.date = date
    }
}

/// Turns full-state snapshots into start and stop events.
public struct SessionTracker: Sendable {
    public private(set) var active: Set<Attribution>

    public init(active: Set<Attribution> = []) {
        self.active = active
    }

    public mutating func apply(_ snapshot: Set<Attribution>, at date: Date) -> [SensorEvent] {
        let ended = active.subtracting(snapshot).sorted()
        let started = snapshot.subtracting(active).sorted()
        active = snapshot
        return ended.map { SensorEvent(kind: .ended, attribution: $0, date: date) }
            + started.map { SensorEvent(kind: .started, attribution: $0, date: date) }
    }
}
