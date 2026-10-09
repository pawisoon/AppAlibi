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

    let store: EventStore?
    @ObservationIgnored private var collector: Collector?
    @ObservationIgnored private var refreshPending = false

    private init() {
        let defaults = UserDefaults.standard
        showLocation = defaults.bool(forKey: Keys.showLocation)
        showSystemInMenu = defaults.bool(forKey: Keys.showSystemInMenu)
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
    }

    // MARK: Collection

    func start() {
        guard collector == nil, let store else { return }
        let collector = Collector(store: store) { state, wroteEvents in
            Task { @MainActor in AppModel.shared.handle(state: state, wroteEvents: wroteEvents) }
        }
        self.collector = collector
        Task { await collector.start() }
        refresh()
    }

    private func handle(state: CollectorState, wroteEvents: Bool) {
        self.state = state
        if wroteEvents { scheduleRefresh() }
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
