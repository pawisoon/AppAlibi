import Foundation

public enum CollectorState: Equatable, Sendable {
    case idle
    case catchingUp(since: Date)
    case watching
    case failed(String)
}

/// Keeps the store in sync with the unified log: catches up with `log show`,
/// then follows `log stream`, restarting it if it exits.
public actor Collector {
    /// Called with the current state, and with the events of each batch once
    /// they are stored. Events are empty for a plain state change.
    public typealias Update = @Sendable (CollectorState, _ events: [CollectedEvent]) -> Void

    private let store: EventStore
    private let initialBackfill: TimeInterval
    private let predicate: String
    private let onUpdate: Update
    private var processor = EventProcessor()
    private var lastProcessed: Date?
    private var task: Task<Void, Never>?
    private var state: CollectorState = .idle

    public init(
        store: EventStore,
        initialBackfill: TimeInterval = 3 * 24 * 3600,
        predicate: String = LogPredicates.combined,
        onUpdate: @escaping Update
    ) {
        self.store = store
        self.initialBackfill = initialBackfill
        self.predicate = predicate
        self.onUpdate = onUpdate
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await self.runForever() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        publish(.idle)
    }

    private func publish(_ newState: CollectorState, events: [CollectedEvent] = []) {
        state = newState
        onUpdate(newState, events)
    }

    private func runForever() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await runOnce()
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                publish(.failed(String(describing: error)))
            }
            // The stream ended or failed. Back off, then catch up and resume.
            let delay = min(60, 2 * pow(2, Double(min(failures, 5))))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func runOnce() async throws {
        lastProcessed = try store.lastProcessed()
        let since = lastProcessed ?? Date().addingTimeInterval(-initialBackfill)
        try await importLockHistory(upTo: lastProcessed)
        if let bootTime = SystemClock.bootTime() { try store.endScreenLock(openBefore: bootTime) }
        processor = EventProcessor(active: try store.openAttributions(), screenLocked: try store.isScreenLocked())

        // Start following first so nothing is lost while catching up.
        let stream = LogReader.run(LogReader.streamArguments(predicate: predicate))

        publish(.catchingUp(since: since))
        for try await batch in LogReader.run(LogReader.showArguments(predicate: predicate, start: since)) {
            try Task.checkCancellation()
            try handle(batch)
        }

        publish(.watching)
        for try await batch in stream {
            try Task.checkCancellation()
            try handle(batch)
        }
    }

    /// Once per database: the lock lines from before the checkpoint, which a
    /// database made before lock tracking skipped. Without a checkpoint the
    /// normal catch-up reads them.
    private func importLockHistory(upTo checkpoint: Date?) async throws {
        guard try store.needsLockHistoryImport() else { return }
        if let checkpoint {
            publish(.catchingUp(since: checkpoint.addingTimeInterval(-initialBackfill)))
            var locks = EventProcessor()
            var events: [CollectedEvent] = []
            let arguments = LogReader.showArguments(predicate: LogPredicates.screenLock,
                                                    start: checkpoint.addingTimeInterval(-initialBackfill), end: checkpoint)
            for try await batch in LogReader.run(arguments) {
                try Task.checkCancellation()
                for entry in batch where entry.timestamp <= checkpoint { events += locks.process(entry) }
            }
            try store.record(events, lastProcessed: nil)
        }
        try store.markLockHistoryImported()
    }

    private func handle(_ batch: [LogEntry]) throws {
        var events: [CollectedEvent] = []
        var newest = lastProcessed
        for entry in batch {
            if let lastProcessed, entry.timestamp <= lastProcessed { continue }
            events += processor.process(entry)
            if newest.map({ entry.timestamp > $0 }) ?? true { newest = entry.timestamp }
        }
        guard newest != lastProcessed else { return }
        try store.record(events, lastProcessed: newest)
        lastProcessed = newest
        if !events.isEmpty { publish(state, events: events) }
    }
}
