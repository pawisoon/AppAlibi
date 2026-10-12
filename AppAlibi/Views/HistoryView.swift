import AlibiKit
import SwiftUI

struct HistoryView: View {
    let model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case sensors = "Sensors"
        case permissions = "Permissions"
        case admin = "Admin"
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .summary: "Summary"
            case .sensors: "Sensors"
            case .permissions: "Permissions"
            case .admin: "Admin"
            }
        }
    }

    var body: some View {
        Group {
            switch model.historyTab {
            case .summary: SummaryView(model: model)
            case .sensors: SensorHistoryView(model: model)
            case .permissions: PermissionHistoryView(model: model)
            case .admin: AdminHistoryView(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { model.historyTab }, set: { model.historyTab = $0 })) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .frame(minWidth: 760, minHeight: 420)
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case day = "24 hours"
    case week = "7 days"
    case month = "30 days"
    case all = "All"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }

    var since: Date? {
        switch self {
        case .day: Date().addingTimeInterval(-86_400)
        case .week: Date().addingTimeInterval(-7 * 86_400)
        case .month: Date().addingTimeInterval(-30 * 86_400)
        case .all: nil
        }
    }
}

// MARK: - Tab state

/// Loads a tab's rows off the main thread and remembers what they were loaded
/// for, so a tab that comes back with nothing changed shows its rows at once.
@MainActor
@Observable
final class TabLoader {
    private(set) var isLoading = false
    @ObservationIgnored private var loaded: AnyHashable?
    @ObservationIgnored private var loads = 0

    /// Runs `fetch` unless the rows are already for `key`, and hands the result
    /// to `apply` unless a newer load started meanwhile. The old rows stay on
    /// screen until then.
    func load<Key: Hashable, T: Sendable>(_ key: Key, model: AppModel,
                                          fetch: @escaping @Sendable (EventStore) throws -> T,
                                          apply: (T) -> Void) async {
        guard loaded != AnyHashable(key) else { return }
        loads += 1
        let load = loads
        isLoading = true
        let result = await model.read(fetch)
        guard load == loads else { return }
        isLoading = false
        loaded = key
        if let result { apply(result) }
    }
}

@MainActor
@Observable
final class SensorsTabState {
    var scope: AppScope = .apps
    var sensor: Sensor?
    var range: TimeRange = .week
    var search = ""
    var sessions: [SensorSession] = []
    var locks = ScreenLockSpans([])
    let loader = TabLoader()
}

@MainActor
@Observable
final class PermissionsTabState {
    var scope: AppScope = .apps
    var range: TimeRange = .week
    var search = ""
    var includePreflight = false
    var filesOnly = false
    var rows: [TCCAggregate] = []
    let loader = TabLoader()
}

@MainActor
@Observable
final class AdminTabState {
    var scope: AppScope = .apps
    var range: TimeRange = .month
    var search = ""
    var rows: [AdminRightAggregate] = []
    let loader = TabLoader()
}

/// How much of the session ran while the screen was locked.
private func lockedTime(of session: SensorSession, in locks: ScreenLockSpans, now: Date = Date()) -> TimeInterval {
    locks.overlap(with: DateInterval(start: session.startedAt, end: max(session.endedAt ?? now, session.startedAt)))
}

// MARK: - Sensors

struct SensorHistoryView: View {
    let model: AppModel
    @Bindable private var state: SensorsTabState

    init(model: AppModel) {
        self.model = model
        state = model.sensorsTab
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScopePicker(scope: $state.scope)
                Picker("Sensor", selection: $state.sensor) {
                    Text("All").tag(Sensor?.none)
                    ForEach(Sensor.known, id: \.self) { Label($0.displayName, systemImage: $0.symbolName).tag(Sensor?.some($0)) }
                }
                .frame(width: 220)
                Picker("Range", selection: $state.range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
                Toggle("While locked", isOn: lockedOnly)
                    .toggleStyle(.checkbox)
                    .help("Only use while the screen was locked.")
                Spacer()
                LoadingIndicator(loader: state.loader)
                Text("Sessions: \(state.sessions.count)").foregroundStyle(.secondary)
                Button("Export\u{2026}", action: export)
                    .disabled(state.sessions.isEmpty)
            }
            .padding(10)

            Table(state.sessions) {
                TableColumn("App") { session in
                    AppCell(identifier: session.app)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Sensor") { session in
                    Label(session.sensor.displayName, systemImage: session.sensor.symbolName)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Started") { session in
                    Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                }
                .width(min: 150, ideal: 180)
                TableColumn("Duration") { session in
                    HStack(spacing: 4) {
                        Text(session.isActive ? String(localized: "Active") : Formatting.duration(session.duration()))
                            .foregroundStyle(session.isActive ? Color.orange : Color.primary)
                        let locked = lockedTime(of: session, in: state.locks)
                        if locked >= ScreenLockSpans.minimumOverlap {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .help("\(Formatting.duration(locked)) of it while the screen was locked")
                                .accessibilityLabel("Partly while the screen was locked")
                        }
                    }
                }
                .width(min: 90, ideal: 110)
            }
            .overlay {
                if state.sessions.isEmpty && !state.loader.isLoading {
                    ContentUnavailableView("No Sessions", systemImage: "eye.slash",
                                           description: Text("Nothing matched in this range."))
                }
            }
        }
        .searchable(text: $state.search, prompt: "Bundle ID")
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: reloadKey) { await reload(reloadKey) }
    }

    private struct ReloadKey: Hashable {
        let sessions: Int
        let locks: Int
        let scope: AppScope
        let sensor: Sensor?
        let range: TimeRange
        let search: String
        let lockedOnly: Bool
    }

    private var reloadKey: ReloadKey {
        ReloadKey(sessions: model.sessionsRevision, locks: model.screenLocksRevision, scope: state.scope,
                  sensor: state.sensor, range: state.range, search: state.search, lockedOnly: model.sensorsLockedOnly)
    }

    private var lockedOnly: Binding<Bool> {
        Binding(get: { model.sensorsLockedOnly }, set: { model.sensorsLockedOnly = $0 })
    }

    private func query(limit: Int) -> SessionQuery {
        SessionQuery(
            sensors: state.sensor.map { [$0] },
            apps: model.sessionApps(in: state.scope),
            appContains: state.search,
            since: state.range.since,
            limit: limit
        )
    }

    private func reload(_ key: ReloadKey) async {
        let rowsQuery = query(limit: 2_000)
        let since = state.range.since
        let lockedOnly = key.lockedOnly
        await state.loader.load(key, model: model, fetch: { (store: EventStore) -> (sessions: [SensorSession], locks: ScreenLockSpans) in
            let locks = AppModel.screenLocks(store, since: since)
            let found = try store.sessions(rowsQuery)
            let sessions = lockedOnly ? found.filter { lockedTime(of: $0, in: locks) >= ScreenLockSpans.minimumOverlap } : found
            return (sessions: sessions, locks: locks)
        }, apply: { result in
            state.sessions = result.sessions
            state.locks = result.locks
        })
    }

    /// The same filters as the table, without its row limit.
    private func export() {
        CSVSaver.save(suggestedName: String(localized: "AppAlibi Sensors")) {
            guard let store = model.store else { return "" }
            let now = Date()
            let locks = AppModel.screenLocks(store, since: nil)
            var rows = (try? store.sessions(query(limit: .max))) ?? []
            if model.sensorsLockedOnly {
                rows = rows.filter { lockedTime(of: $0, in: locks, now: now) >= ScreenLockSpans.minimumOverlap }
            }
            return CSVExport.sessions(rows, locks: locks, now: now) { AppInfo.info(for: $0).name }
        }
    }
}

// MARK: - Permissions

struct PermissionHistoryView: View {
    let model: AppModel
    @Bindable private var state: PermissionsTabState

    init(model: AppModel) {
        self.model = model
        state = model.permissionsTab
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ScopePicker(scope: $state.scope)
                Picker("Range", selection: $state.range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
                Toggle("Files & folders only", isOn: $state.filesOnly)
                Toggle("Preflight checks", isOn: $state.includePreflight)
                    .help("Preflight checks ask whether access is allowed without accessing anything.")
                Spacer()
                LoadingIndicator(loader: state.loader)
                Button("Export\u{2026}", action: export)
                    .disabled(state.rows.isEmpty)
            }
            .toggleStyle(.checkbox)
            .padding(10)

            Table(state.rows) {
                TableColumn("App") { row in
                    AppCell(identifier: row.app, binaryPath: row.binaryPath, detail: row.accessor.isEmpty || row.accessor == row.app ? nil : String(localized: "via \(row.accessor)"))
                }
                .width(min: 200, ideal: 280)
                TableColumn("Permission") { row in
                    Text(row.serviceName)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Result") { row in
                    Text(row.preflight ? String(localized: "\(row.resultName) (check)") : row.resultName)
                        .foregroundStyle(row.authValue == 0 ? Color.red : row.authValue == 2 ? Color.primary : Color.secondary)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Count") { row in
                    Text("\(row.count)").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Last Seen") { row in
                    Text(row.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 130, ideal: 160)
            }
            .overlay {
                if state.rows.isEmpty && !state.loader.isLoading {
                    ContentUnavailableView("No Permission Checks", systemImage: "lock.shield",
                                           description: Text("Try including preflight checks or another scope."))
                }
            }
        }
        .searchable(text: $state.search, prompt: "App or path")
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: reloadKey) { await reload(reloadKey) }
    }

    private struct ReloadKey: Hashable {
        let permissions: Int
        let range: TimeRange
        let search: String
        let preflight: Bool
        let scope: AppScope
        let files: Bool
    }

    private var reloadKey: ReloadKey {
        ReloadKey(permissions: model.permissionsRevision, range: state.range, search: state.search,
                  preflight: state.includePreflight, scope: state.scope, files: state.filesOnly)
    }

    private func query(limit: Int) -> TCCQuery {
        TCCQuery(
            apps: model.tccApps(in: state.scope),
            includePreflight: state.includePreflight,
            includeApple: true,
            fileAccessOnly: state.filesOnly,
            appContains: state.search,
            since: state.range.since,
            limit: limit
        )
    }

    private func reload(_ key: ReloadKey) async {
        let rowsQuery = query(limit: 2_000)
        await state.loader.load(key, model: model, fetch: { store in
            try store.tccAggregates(rowsQuery)
        }, apply: { state.rows = $0 })
    }

    /// The same filters as the table, without its row limit.
    private func export() {
        CSVSaver.save(suggestedName: String(localized: "AppAlibi Permissions")) {
            let rows = (try? model.store?.tccAggregates(query(limit: .max))) ?? []
            return CSVExport.permissions(rows) { identifier, binaryPath in
                AppInfo.info(for: identifier, binaryPath: binaryPath.isEmpty ? nil : binaryPath).name
            }
        }
    }
}

// MARK: - Admin rights

struct AdminHistoryView: View {
    let model: AppModel
    @Bindable private var state: AdminTabState

    init(model: AppModel) {
        self.model = model
        state = model.adminTab
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ScopePicker(scope: $state.scope)
                Picker("Range", selection: $state.range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
                Spacer()
                LoadingIndicator(loader: state.loader)
                Button("Export\u{2026}", action: export)
                    .disabled(state.rows.isEmpty)
            }
            .padding(10)

            Table(state.rows) {
                TableColumn("App") { row in
                    AppCell(identifier: Self.name(row.app), binaryPath: row.app,
                            detail: row.client == row.app ? nil : String(localized: "via \(Self.name(row.client))"))
                }
                .width(min: 200, ideal: 250)
                TableColumn("Right") { row in
                    Text(row.rightName)
                        .lineLimit(2)
                        .help(row.rightName + "\n" + row.right)
                }
                .width(min: 180, ideal: 320)
                TableColumn("Count") { row in
                    Text("\(row.count)").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Last Seen") { row in
                    Text(row.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 130, ideal: 160)
            }
            .overlay {
                if state.rows.isEmpty && !state.loader.isLoading {
                    ContentUnavailableView("No Admin Rights", systemImage: "person.badge.key",
                                           description: Text("Nothing was granted administrator rights in this range. Try System or All."))
                }
            }
        }
        .searchable(text: $state.search, prompt: "App, path or right")
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: reloadKey) { await reload(reloadKey) }
    }

    private struct ReloadKey: Hashable {
        let adminRights: Int
        let range: TimeRange
        let search: String
        let scope: AppScope
    }

    private var reloadKey: ReloadKey {
        ReloadKey(adminRights: model.adminRightsRevision, range: state.range, search: state.search, scope: state.scope)
    }

    /// authd logs paths, not bundle IDs: `/usr/libexec/mdmclient` -> `mdmclient`,
    /// `/System/.../SoftwareUpdateNotificationManager.app` -> `SoftwareUpdateNotificationManager`.
    private static func name(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func query(limit: Int) -> AdminRightQuery {
        AdminRightQuery(apps: model.adminRightApps(in: state.scope), appContains: state.search, since: state.range.since, limit: limit)
    }

    private func reload(_ key: ReloadKey) async {
        let rowsQuery = query(limit: 2_000)
        await state.loader.load(key, model: model, fetch: { store in
            try store.adminRights(rowsQuery)
        }, apply: { state.rows = $0 })
    }

    /// The same filters as the table, without its row limit.
    private func export() {
        CSVSaver.save(suggestedName: String(localized: "AppAlibi Admin Rights")) {
            let rows = (try? model.store?.adminRights(query(limit: .max))) ?? []
            return CSVExport.adminRights(rows) { path in AppInfo.info(for: Self.name(path), binaryPath: path).name }
        }
    }
}

/// A small spinner while a tab loads. The old rows stay visible meanwhile.
struct LoadingIndicator: View {
    let loader: TabLoader

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(loader.isLoading ? 1 : 0)
            .accessibilityHidden(!loader.isLoading)
    }
}

/// Apps, system services, or both.
struct ScopePicker: View {
    @Binding var scope: AppScope

    var body: some View {
        Picker("Show", selection: $scope) {
            ForEach(AppScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Apps you installed or opened, or the system services that run in the background.")
    }
}

struct AppCell: View {
    let identifier: String
    var binaryPath: String?
    var detail: String?

    var body: some View {
        let info = AppInfo.info(for: identifier, binaryPath: binaryPath)
        HStack(spacing: 6) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name).lineLimit(1)
                if info.name != identifier || detail != nil {
                    Text(detail ?? identifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(binaryPath ?? identifier)
    }
}
