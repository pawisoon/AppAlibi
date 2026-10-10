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

// MARK: - Sensors

struct SensorHistoryView: View {
    let model: AppModel

    @State private var scope: AppScope = .apps
    @State private var sensor: Sensor?
    @State private var range: TimeRange = .week
    @State private var search = ""
    @State private var sessions: [SensorSession] = []
    @State private var locks = ScreenLockSpans([])

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScopePicker(scope: $scope)
                Picker("Sensor", selection: $sensor) {
                    Text("All").tag(Sensor?.none)
                    ForEach(Sensor.known, id: \.self) { Label($0.displayName, systemImage: $0.symbolName).tag(Sensor?.some($0)) }
                }
                .frame(width: 220)
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
                Toggle("While locked", isOn: lockedOnly)
                    .toggleStyle(.checkbox)
                    .help("Only use while the screen was locked.")
                Spacer()
                Text("Sessions: \(sessions.count)").foregroundStyle(.secondary)
                Button("Export\u{2026}", action: export)
                    .disabled(sessions.isEmpty)
            }
            .padding(10)

            Table(sessions) {
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
                        let locked = lockedTime(session)
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
                if sessions.isEmpty {
                    ContentUnavailableView("No Sessions", systemImage: "eye.slash",
                                           description: Text("Nothing matched in this range."))
                }
            }
        }
        .searchable(text: $search, prompt: "Bundle ID")
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: ReloadKey(revision: model.revision, scope: scope, sensor: sensor, range: range, search: search,
                            lockedOnly: model.sensorsLockedOnly)) {
            reload()
        }
    }

    private struct ReloadKey: Equatable {
        let revision: Int
        let scope: AppScope
        let sensor: Sensor?
        let range: TimeRange
        let search: String
        let lockedOnly: Bool
    }

    private var lockedOnly: Binding<Bool> {
        Binding(get: { model.sensorsLockedOnly }, set: { model.sensorsLockedOnly = $0 })
    }

    private func lockedTime(_ session: SensorSession) -> TimeInterval {
        let end = max(session.endedAt ?? Date(), session.startedAt)
        return locks.overlap(with: DateInterval(start: session.startedAt, end: end))
    }

    private func query(limit: Int) -> SessionQuery {
        SessionQuery(
            sensors: sensor.map { [$0] },
            apps: model.sessionApps(in: scope),
            appContains: search,
            since: range.since,
            limit: limit
        )
    }

    private func reload() {
        locks = model.screenLocks(since: range.since)
        let found = (try? model.store?.sessions(query(limit: 2_000))) ?? []
        sessions = model.sensorsLockedOnly ? found.filter { lockedTime($0) >= ScreenLockSpans.minimumOverlap } : found
    }

    /// The same filters as the table, without its row limit.
    private func export() {
        CSVSaver.save(suggestedName: String(localized: "AppAlibi Sensors")) {
            let now = Date()
            let locks = model.screenLocks(since: nil)
            var rows = (try? model.store?.sessions(query(limit: .max))) ?? []
            if model.sensorsLockedOnly {
                rows = rows.filter {
                    locks.overlap(with: DateInterval(start: $0.startedAt, end: max($0.endedAt ?? now, $0.startedAt)))
                        >= ScreenLockSpans.minimumOverlap
                }
            }
            return CSVExport.sessions(rows, locks: locks, now: now) { AppInfo.info(for: $0).name }
        }
    }
}

// MARK: - Permissions

struct PermissionHistoryView: View {
    let model: AppModel

    @State private var scope: AppScope = .apps
    @State private var range: TimeRange = .week
    @State private var search = ""
    @State private var includePreflight = false
    @State private var filesOnly = false
    @State private var rows: [TCCAggregate] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ScopePicker(scope: $scope)
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
                Toggle("Files & folders only", isOn: $filesOnly)
                Toggle("Preflight checks", isOn: $includePreflight)
                    .help("Preflight checks ask whether access is allowed without accessing anything.")
                Spacer()
                Button("Export\u{2026}", action: export)
                    .disabled(rows.isEmpty)
            }
            .toggleStyle(.checkbox)
            .padding(10)

            Table(rows) {
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
                if rows.isEmpty {
                    ContentUnavailableView("No Permission Checks", systemImage: "lock.shield",
                                           description: Text("Try including preflight checks or another scope."))
                }
            }
        }
        .searchable(text: $search, prompt: "App or path")
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: ReloadKey(revision: model.revision, range: range, search: search,
                            preflight: includePreflight, scope: scope, files: filesOnly)) {
            reload()
        }
    }

    private struct ReloadKey: Equatable {
        let revision: Int
        let range: TimeRange
        let search: String
        let preflight: Bool
        let scope: AppScope
        let files: Bool
    }

    private func query(limit: Int) -> TCCQuery {
        TCCQuery(
            apps: model.tccApps(in: scope),
            includePreflight: includePreflight,
            includeApple: true,
            fileAccessOnly: filesOnly,
            appContains: search,
            since: range.since,
            limit: limit
        )
    }

    private func reload() {
        rows = (try? model.store?.tccAggregates(query(limit: 2_000))) ?? []
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

    @State private var scope: AppScope = .apps
    @State private var range: TimeRange = .month
    @State private var search = ""
    @State private var rows: [AdminRightAggregate] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ScopePicker(scope: $scope)
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
                Spacer()
                Button("Export\u{2026}", action: export)
                    .disabled(rows.isEmpty)
            }
            .padding(10)

            Table(rows) {
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
                if rows.isEmpty {
                    ContentUnavailableView("No Admin Rights", systemImage: "person.badge.key",
                                           description: Text("Nothing was granted administrator rights in this range. Try System or All."))
                }
            }
        }
        .searchable(text: $search, prompt: "App, path or right")
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: ReloadKey(revision: model.revision, range: range, search: search, scope: scope)) {
            reload()
        }
    }

    private struct ReloadKey: Equatable {
        let revision: Int
        let range: TimeRange
        let search: String
        let scope: AppScope
    }

    /// authd logs paths, not bundle IDs: `/usr/libexec/mdmclient` -> `mdmclient`,
    /// `/System/.../SoftwareUpdateNotificationManager.app` -> `SoftwareUpdateNotificationManager`.
    private static func name(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func query(limit: Int) -> AdminRightQuery {
        AdminRightQuery(apps: model.adminRightApps(in: scope), appContains: search, since: range.since, limit: limit)
    }

    private func reload() {
        rows = (try? model.store?.adminRights(query(limit: 2_000))) ?? []
    }

    /// The same filters as the table, without its row limit.
    private func export() {
        CSVSaver.save(suggestedName: String(localized: "AppAlibi Admin Rights")) {
            let rows = (try? model.store?.adminRights(query(limit: .max))) ?? []
            return CSVExport.adminRights(rows) { path in AppInfo.info(for: Self.name(path), binaryPath: path).name }
        }
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
