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
    /// Bump per source whenever new events are stored, so open views reload
    /// only when something they show changed. Separate properties, so a view
    /// is not even redrawn for a source it does not read.
    private(set) var sessionsRevision = 0
    private(set) var permissionsRevision = 0
    private(set) var adminRightsRevision = 0
    private(set) var screenLocksRevision = 0
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
    /// Each history tab's filters and rows. Kept here so switching tabs shows
    /// the last rows at once and keeps the filters.
    let sensorsTab = SensorsTabState()
    let permissionsTab = PermissionsTabState()
    let adminTab = AdminTabState()
    let summaryTab = SummaryTabState()

    let store: EventStore?
    @ObservationIgnored private var collector: Collector?
    @ObservationIgnored private var pendingSources: Set<StoredSource> = []
    @ObservationIgnored private var menuLoads = 0
    @ObservationIgnored private var pruneTimer: Timer?
    /// Identifiers in each source with their kind, so a scope filter does not
    /// scan a whole table and classify every app on each reload. Read once on
    /// first use, then extended from each stored batch. nil until read.
    @ObservationIgnored private var sessionAppKinds: [String: AppKind]?
    @ObservationIgnored private var tccAppKinds: [String: AppKind]?
    @ObservationIgnored private var adminAppKinds: [String: AppKind]?

    private init() {
        let defaults = UserDefaults.standard
        showLocation = defaults.bool(forKey: Keys.showLocation)
        showSystemInMenu = defaults.bool(forKey: Keys.showSystemInMenu)
        retention = HistoryRetention(rawValue: defaults.integer(forKey: Keys.retention)) ?? .forever
        do {
            store = try EventStore()
        } catch {
            store = nil
            storeError = String(localized: "Could not open the history database: \(String(describing: error))")
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
        learnApps(from: events)
        scheduleRefresh(for: events)
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

    /// Coalesces bursts (catch-up writes many batches) into one refresh, and
    /// reloads only what the batches touched.
    private func scheduleRefresh(for events: [CollectedEvent]) {
        let wasIdle = pendingSources.isEmpty
        pendingSources.formUnion(events.map(StoredSource.init))
        guard wasIdle else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let sources = pendingSources
            pendingSources = []
            bump(sources)
            if sources.contains(.sessions) { refresh() }
        }
    }

    /// Reloads the menu's sessions.
    func refresh() {
        guard let store else { return }
        let sensors = visibleSensors
        let apps = showSystemInMenu ? nil : sessionApps(in: .apps)
        menuLoads += 1
        let load = menuLoads
        Task {
            let found = await Self.read(store) { store in
                (active: try store.sessions(SessionQuery(sensors: sensors, apps: apps, onlyActive: true, limit: 50)),
                 recent: try store.sessions(SessionQuery(sensors: sensors, apps: apps, limit: 30)))
            }
            // A newer load started while this one ran.
            guard load == menuLoads else { return }
            activeSessions = found?.active ?? []
            recentSessions = (found?.recent ?? []).filter { !$0.isActive }.prefix(8).map { $0 }
        }
    }

    /// History changed under every view: deleted, pruned, or a setting that
    /// changes what is counted.
    private func reloadEverything() {
        sessionAppKinds = nil
        tccAppKinds = nil
        adminAppKinds = nil
        bump(Set(StoredSource.allCases))
        refresh()
    }

    private func bump(_ sources: Set<StoredSource>) {
        if sources.contains(.sessions) { sessionsRevision += 1 }
        if sources.contains(.permissions) { permissionsRevision += 1 }
        if sources.contains(.adminRights) { adminRightsRevision += 1 }
        if sources.contains(.screenLocks) { screenLocksRevision += 1 }
    }

    /// Runs a store query off the main thread. Reads have their own connection,
    /// so they do not wait for the collector's writes either.
    nonisolated static func read<T: Sendable>(_ store: EventStore, _ body: @escaping @Sendable (EventStore) throws -> T) async -> T? {
        await Task.detached(priority: .userInitiated) { try? body(store) }.value
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (EventStore) throws -> T) async -> T? {
        guard let store else { return nil }
        return await Self.read(store, body)
    }

    /// Sensors shown in the menu. Location is hidden by default because
    /// "System Services" uses it every few minutes.
    var visibleSensors: Set<Sensor>? {
        showLocation ? nil : Set(Sensor.known.filter(\.isSensitive))
    }

    /// Identifiers with sensor sessions that fall in the scope. nil means no filter.
    func sessionApps(in scope: AppScope) -> Set<String>? {
        guard let kind = scope.kind, let store else { return nil }
        if sessionAppKinds == nil {
            var kinds: [String: AppKind] = [:]
            for app in (try? store.sessionApps()) ?? [] { Self.add(app, AppInfo.kind(for: app), to: &kinds) }
            sessionAppKinds = kinds
        }
        return Self.apps(in: sessionAppKinds ?? [:], of: kind)
    }

    /// Identifiers with permission checks that fall in the scope. nil means no filter.
    func tccApps(in scope: AppScope) -> Set<String>? {
        guard let kind = scope.kind, let store else { return nil }
        if tccAppKinds == nil {
            var kinds: [String: AppKind] = [:]
            for (app, path) in (try? store.tccApps()) ?? [] { Self.add(app, AppInfo.kind(for: app, binaryPath: path), to: &kinds) }
            tccAppKinds = kinds
        }
        return Self.apps(in: tccAppKinds ?? [:], of: kind)
    }

    /// App paths with admin rights that fall in the scope. nil means no filter.
    func adminRightApps(in scope: AppScope) -> Set<String>? {
        guard let kind = scope.kind, let store else { return nil }
        if adminAppKinds == nil {
            var kinds: [String: AppKind] = [:]
            for path in (try? store.adminRightApps()) ?? [] { Self.add(path, Self.adminKind(path), to: &kinds) }
            adminAppKinds = kinds
        }
        return Self.apps(in: adminAppKinds ?? [:], of: kind)
    }

    /// Adds the identifiers of a stored batch to the kinds already read.
    private func learnApps(from events: [CollectedEvent]) {
        for event in events {
            switch event {
            case .sensor(let event):
                let app = event.attribution.app
                if sessionAppKinds != nil, sessionAppKinds?[app] == nil {
                    Self.add(app, AppInfo.kind(for: app), to: &sessionAppKinds!)
                }
            case .tcc(let event):
                if tccAppKinds != nil, tccAppKinds?[event.app] != .app {
                    Self.add(event.app, AppInfo.kind(for: event.app, binaryPath: event.binaryPath), to: &tccAppKinds!)
                }
            case .adminRight(let event):
                if adminAppKinds != nil, adminAppKinds?[event.app] == nil {
                    Self.add(event.app, Self.adminKind(event.app), to: &adminAppKinds!)
                }
            case .screenLock:
                break
            }
        }
    }

    /// An identifier counts as an app if any of its logged binaries is one.
    private static func add(_ identifier: String, _ kind: AppKind, to kinds: inout [String: AppKind]) {
        if kinds[identifier] != .app { kinds[identifier] = kind }
    }

    private static func apps(in kinds: [String: AppKind], of kind: AppKind) -> Set<String> {
        Set(kinds.compactMap { $0.value == kind ? $0.key : nil })
    }

    private static func adminKind(_ path: String) -> AppKind {
        AppInfo.kind(for: (path as NSString).lastPathComponent, binaryPath: path)
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

    /// Builds the Summary tab's report from the store, to run off the main
    /// thread. The scope is resolved first, here, because classifying apps
    /// needs the main thread.
    func reportFetch(_ interval: DateInterval, bucket: Calendar.Component?,
                     scope: AppScope) -> @Sendable (EventStore) throws -> ActivityReport {
        let sessionScope = sessionApps(in: scope)
        let tccScope = tccApps(in: scope)
        let includeLocation = showLocation
        return { store in
            try ActivityReport.build(store: store, interval: interval, bucket: bucket,
                                     includeLocation: includeLocation) { identifier, binaryPath in
                // Sessions come without a path, permission rows with one.
                let apps = binaryPath == nil ? sessionScope : tccScope
                return apps?.contains(identifier) ?? true
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
        case .idle: String(localized: "Starting…")
        case .catchingUp(let since): String(localized: "Catching up since \(since.formatted(date: .abbreviated, time: .shortened))…")
        case .watching: String(localized: "Watching")
        case .failed(let message): String(localized: "Error: \(message)")
        }
    }

    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    // MARK: Settings

    func setShowLocation(_ value: Bool) {
        showLocation = value
        UserDefaults.standard.set(value, forKey: Keys.showLocation)
        // The Summary counts location only when it is shown.
        bump([.sessions])
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
                    await MainActor.run { AppModel.shared.reloadEverything() }
                }
            } catch {
                await MainActor.run { AppModel.shared.storeError = String(localized: "Could not delete old history: \(String(describing: error))") }
            }
        }
    }

    /// Locks from `since` until now, for marking use while nobody was at the Mac.
    nonisolated static func screenLocks(_ store: EventStore, since: Date?) -> ScreenLockSpans {
        let now = Date()
        let interval = since.map { DateInterval(start: min($0, now), end: now) }
        return (try? store.screenLocks(overlapping: interval, now: now)) ?? ScreenLockSpans([])
    }

    func deleteHistory() {
        do {
            try store?.deleteAll()
        } catch {
            storeError = String(localized: "Could not delete history: \(String(describing: error))")
        }
        reloadEverything()
    }

    func revealDatabase() {
        guard let path = store?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The kinds of history a stored batch can change.
enum StoredSource: CaseIterable {
    case sessions, permissions, adminRights, screenLocks

    init(_ event: CollectedEvent) {
        switch event {
        case .sensor: self = .sessions
        case .tcc: self = .permissions
        case .adminRight: self = .adminRights
        case .screenLock: self = .screenLocks
        }
    }
}
