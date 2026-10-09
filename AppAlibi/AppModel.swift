import AlibiKit
import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var state: CollectorState = .idle
    private(set) var activeSessions: [SensorSession] = []
    private(set) var recentSessions: [SensorSession] = []
    /// Bumps whenever new events are stored, so open views can reload.
    private(set) var revision = 0
    private(set) var storeError: String?
    private(set) var showLocation: Bool
    private(set) var showSystemInMenu: Bool
    private(set) var retention: HistoryRetention
    /// The history window's tab. Here rather than in the view so a click on a
    /// notification can pick it.
    var historyTab: HistoryView.Tab = .summary
    /// The Sensors tab's "While locked" filter, set by a click on the unlock notification.
    var sensorsLockedOnly = false
    var summaryPeriod: ReportPeriod = .day
    /// Any date inside the day or week the Summary tab shows.
    var summaryDate = Date()

    let store: EventStore?
    @ObservationIgnored private var collector: Collector?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var pruneTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        showLocation = defaults.bool(forKey: Keys.showLocation)
        showSystemInMenu = defaults.bool(forKey: Keys.showSystemInMenu)
        retention = HistoryRetention(rawValue: defaults.integer(forKey: Keys.retention)) ?? .forever
        do {
            store = try EventStore()
        } catch {
            store = nil
            storeError = "Could not open the history database: \(error)"
        }
    }

    private enum Keys {
        static let showLocation = "showLocation"
        static let showSystemInMenu = "showSystemInMenu"
        static let retention = "appalibi.history.retentionMonths"
    }

    // MARK: Collection

    func start() {
        guard collector == nil, let store else { return }
        let collector = Collector(store: store) { state, events in
            Task { @MainActor in AppModel.shared.handle(state: state, events: events) }
        }
        self.collector = collector
        Task { await collector.start() }
        refresh()
        startPruning()
    }

    private func handle(state: CollectorState, events: [CollectedEvent]) {
        self.state = state
        guard !events.isEmpty else { return }
        scheduleRefresh()
        postAlerts(for: events)
    }

    /// Runs on every stored batch. The planner drops anything older than a
    /// couple of minutes, so catching up on the log at launch stays quiet.
    private func postAlerts(for events: [CollectedEvent]) {
        let settings = AlertPreferences.alertSettings
        guard settings.isEnabled, let store else { return }
        let planner = AlertPlanner(store: store, settings: settings) { identifier, binaryPath in
            MainActor.assumeIsolated { AppInfo.kind(for: identifier, binaryPath: binaryPath) == .app }
        }
        for alert in (try? planner.alerts(for: events)) ?? [] {
            Notifier.shared.post(alert)
        }
    }

    /// Coalesces bursts (catch-up writes many batches) into one refresh.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            refreshPending = false
            refresh()
        }
    }

    func refresh() {
        guard let store else { return }
        let sensors = visibleSensors
        let apps = showSystemInMenu ? nil : sessionApps(in: .apps)
        activeSessions = (try? store.sessions(SessionQuery(sensors: sensors, apps: apps, onlyActive: true, limit: 50))) ?? []
        recentSessions = ((try? store.sessions(SessionQuery(sensors: sensors, apps: apps, limit: 30))) ?? [])
            .filter { !$0.isActive }
            .prefix(8)
            .map { $0 }
        revision += 1
    }

    /// Sensors shown in the menu. Location is hidden by default because
    /// "System Services" uses it every few minutes.
    var visibleSensors: Set<Sensor>? {
        showLocation ? nil : Set(Sensor.known.filter(\.isSensitive))
    }

    /// Identifiers with sensor sessions that fall in the scope. nil means no filter.
    func sessionApps(in scope: AppScope) -> Set<String>? {
        guard let kind = scope.kind, let store else { return nil }
        let apps = (try? store.sessionApps()) ?? []
        return Set(apps.filter { AppInfo.kind(for: $0) == kind })
    }

    /// Identifiers with permission checks that fall in the scope. nil means no filter.
    func tccApps(in scope: AppScope) -> Set<String>? {
        guard let kind = scope.kind, let store else { return nil }
        var kinds: [String: AppKind] = [:]
        for (app, path) in (try? store.tccApps()) ?? [] {
            // An identifier counts as an app if any of its logged binaries is one.
            if kinds[app] == .app { continue }
            kinds[app] = AppInfo.kind(for: app, binaryPath: path)
        }
        return Set(kinds.filter { $0.value == kind }.keys)
    }

    /// Activity in the interval, split into chart bars if `bucket` is given.
    func report(_ interval: DateInterval, now: Date = Date(), bucket: Calendar.Component? = nil,
                scope: AppScope = .apps) -> ActivityReport? {
        guard let store else { return nil }
        return try? ActivityReport.build(store: store, interval: interval, now: now, bucket: bucket,
                                         includeLocation: showLocation) { identifier, binaryPath in
            MainActor.assumeIsolated {
                guard let kind = scope.kind else { return true }
                return AppInfo.kind(for: identifier, binaryPath: binaryPath) == kind
            }
        }
    }

    func showSummary(_ period: ReportPeriod) {
        summaryPeriod = period
        summaryDate = Date()
        historyTab = .summary
    }

    var isSensitiveSensorActive: Bool {
        activeSessions.contains { $0.sensor.isSensitive }
    }

    var statusText: String {
        switch state {
        case .idle: "Starting…"
        case .catchingUp(let since): "Catching up since \(since.formatted(date: .abbreviated, time: .shortened))…"
        case .watching: "Watching"
        case .failed(let message): "Error: \(message)"
        }
    }

    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    // MARK: Settings

    func setShowLocation(_ value: Bool) {
        showLocation = value
        UserDefaults.standard.set(value, forKey: Keys.showLocation)
        refresh()
    }

    func setShowSystemInMenu(_ value: Bool) {
        showSystemInMenu = value
        UserDefaults.standard.set(value, forKey: Keys.showSystemInMenu)
        refresh()
    }

    /// Applies the retention setting now and every few hours after.
    private func startPruning() {
        pruneHistory()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.pruneHistory() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    func setRetention(_ value: HistoryRetention) {
        retention = value
        UserDefaults.standard.set(value.rawValue, forKey: Keys.retention)
        pruneHistory()
    }

    func pruneHistory(now: Date = Date()) {
        guard let store, let cutoff = retention.cutoff(before: now) else { return }
        Task.detached(priority: .utility) {
            do {
                if try store.deleteOlderThan(cutoff) > 0 {
                    await MainActor.run { AppModel.shared.refresh() }
                }
            } catch {
                await MainActor.run { AppModel.shared.storeError = "Could not delete old history: \(error)" }
            }
        }
    }

    /// Locks from `since` until now, for marking use while nobody was at the Mac.
    func screenLocks(since: Date?) -> ScreenLockSpans {
        let now = Date()
        let interval = since.map { DateInterval(start: min($0, now), end: now) }
        return (try? store?.screenLocks(overlapping: interval, now: now)) ?? ScreenLockSpans([])
    }

    func deleteHistory() {
        do {
            try store?.deleteAll()
        } catch {
            storeError = "Could not delete history: \(error)"
        }
        refresh()
    }

    func revealDatabase() {
        guard let path = store?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
