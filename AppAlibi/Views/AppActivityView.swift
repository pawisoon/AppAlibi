import AlibiKit
import AppKit
import SwiftUI

/// Which app an activity window shows. The value of its window scene, so
/// opening the same app twice brings its window forward.
struct AppActivityTarget: Codable, Hashable {
    /// The identifier sessions and permission checks use: a bundle ID, or a name.
    let identifier: String
    /// A binary or bundle path, when the row it came from had one.
    var binaryPath: String?

    init(identifier: String, binaryPath: String? = nil) {
        self.identifier = identifier
        self.binaryPath = binaryPath?.isEmpty == true ? nil : binaryPath
    }

    /// authd logs paths only. Takes the bundle ID of the app around the path
    /// when there is one, so the window also finds its sessions and checks.
    @MainActor
    init(adminPath path: String) {
        let identifier = AppInfo.bundleIdentifier(containing: path) ?? {
            let name = (path as NSString).lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }()
        self.init(identifier: identifier, binaryPath: path)
    }
}

/// Everything one app did, newest first, grouped by day: sensor use, permission
/// checks and admin rights. The folders it reached for open in Finder.
struct AppActivityView: View {
    let model: AppModel
    let target: AppActivityTarget

    enum Filter: String, CaseIterable, Identifiable {
        case all, sensors, permissions, admin
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .sensors: "Sensors"
            case .permissions: "Permissions"
            case .admin: "Admin"
            }
        }

        func includes(_ event: AppTimelineEvent) -> Bool {
            switch (self, event) {
            case (.all, _), (.sensors, .sensor), (.permissions, .permission), (.admin, .admin): true
            default: false
            }
        }
    }

    private struct Day: Identifiable {
        let date: Date
        let events: [AppTimelineEvent]
        var id: Date { date }
    }

    @State private var range: TimeRange = .month
    @State private var filter: Filter = .all
    @State private var includePreflight = false
    @State private var activity = AppActivity.empty
    @State private var loader = TabLoader()

    var body: some View {
        let info = AppInfo.info(for: target.identifier, binaryPath: target.binaryPath)
        VStack(spacing: 0) {
            header(info)
            Divider()
            controls
            List {
                overview
                if !activity.folders.isEmpty, filter == .all || filter == .permissions {
                    folders
                }
                ForEach(days) { day in
                    Section(day.date.formatted(date: .complete, time: .omitted)) {
                        ForEach(day.events) { TimelineRow(event: $0) }
                    }
                }
            }
            .overlay {
                if days.isEmpty && !loader.isLoading {
                    ContentUnavailableView("No Activity", systemImage: "clock",
                                           description: Text("Nothing recorded for this app in this range."))
                }
            }
        }
        .navigationTitle(info.name)
        .frame(minWidth: 660, minHeight: 480)
        .task(id: reloadKey) { await reload(reloadKey) }
    }

    // MARK: Header

    private func header(_ info: AppInfo.Info) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.title2.weight(.semibold)).lineLimit(1)
                Text(target.identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                if let path = bundlePath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let path = bundlePath {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .padding(14)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Range", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 160)
            Toggle("Preflight checks", isOn: $includePreflight)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Preflight checks ask whether access is allowed without accessing anything.")
            Spacer(minLength: 0)
            LoadingIndicator(loader: loader)
        }
        .padding(10)
    }

    // MARK: Overview

    private var overview: some View {
        Section("Overview") {
            HStack(alignment: .top, spacing: 20) {
                ForEach(activity.sensorTime, id: \.sensor) { item in
                    Stat(value: SummaryView.long(item.duration), title: item.sensor.displayName, symbol: item.sensor.symbolName)
                }
                Stat(value: activity.permissionChecks.formatted(), title: String(localized: "Permission checks"), symbol: "lock.shield")
                if activity.deniedChecks > 0 {
                    Stat(value: activity.deniedChecks.formatted(), title: String(localized: "Denied"), symbol: "xmark.shield", tint: .red)
                }
                if activity.adminGrants > 0 {
                    Stat(value: activity.adminGrants.formatted(), title: String(localized: "Admin rights"), symbol: "person.badge.key")
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private struct Stat: View {
        let value: String
        let title: String
        let symbol: String
        var tint: Color = .secondary

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Folders

    private var folders: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(activity.folders) { FolderTile(access: $0) }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Folders")
        } footer: {
            Text("Click a folder to open it in Finder. macOS logs which protected folder an app reached for, not which files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Loading

    private var days: [Day] {
        let calendar = Calendar.current
        let now = Date()
        var order: [Date] = []
        var byDay: [Date: [AppTimelineEvent]] = [:]
        for event in activity.timeline where filter.includes(event) {
            let day = calendar.startOfDay(for: event.end(now: now))
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(event)
        }
        return order.map { Day(date: $0, events: byDay[$0] ?? []) }
    }

    /// The app's bundle, or the binary when it is not in one.
    private var bundlePath: String? {
        AppInfo.bundleURL(for: target.identifier, binaryPath: target.binaryPath)?.path ?? target.binaryPath
    }

    private struct ReloadKey: Hashable {
        let sessions: Int
        let permissions: Int
        let adminRights: Int
        let range: TimeRange
        let preflight: Bool
    }

    private var reloadKey: ReloadKey {
        ReloadKey(sessions: model.sessionsRevision, permissions: model.permissionsRevision,
                  adminRights: model.adminRightsRevision, range: range, preflight: includePreflight)
    }

    private func reload(_ key: ReloadKey) async {
        let query = AppActivityQuery(identifier: target.identifier, paths: AppInfo.paths(for: target.identifier, binaryPath: target.binaryPath),
                                     since: key.range.since, includePreflight: key.preflight)
        await loader.load(key, model: model, fetch: { store in
            try store.appActivity(query)
        }, apply: { activity = $0 })
    }
}

/// A protected folder the app reached for. Opens it in Finder.
private struct FolderTile: View {
    let access: AppFolderAccess

    var body: some View {
        let url = ProtectedFolder.url(for: access.service)
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let url, FileManager.default.fileExists(atPath: url.path) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                    } else {
                        Image(systemName: "folder").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(access.serviceName).lineLimit(1)
                    HStack(spacing: 6) {
                        if access.allowed > 0 { Text("Allowed: \(access.allowed)") }
                        if access.denied > 0 { Text("Denied: \(access.denied)").foregroundStyle(.red) }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    Text("Last: \(Formatting.time(access.lastSeen))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url?.path ?? access.serviceName)
    }
}

/// One line of the timeline.
private struct TimelineRow: View {
    let event: AppTimelineEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 1)
    }

    private var symbol: String {
        switch event {
        case .sensor(let session): session.sensor.symbolName
        case .permission(let row): ProtectedFolder.isFolder(row.service) ? "folder.fill" : "lock.shield"
        case .admin: "person.badge.key.fill"
        }
    }

    private var tint: Color {
        switch event {
        case .sensor(let session): session.isActive ? .orange : .accentColor
        case .permission(let row): row.authValue == 0 ? .red : .secondary
        case .admin: .purple
        }
    }

    private var title: String {
        switch event {
        case .sensor(let session): session.sensor.displayName
        case .permission(let row): row.serviceName
        case .admin(let row): row.rightName
        }
    }

    private var subtitle: String {
        switch event {
        case .sensor(let session):
            if session.isActive {
                return String(localized: "Since \(Self.time(session.startedAt))")
            }
            return "\(Self.time(session.startedAt)) – \(Self.time(session.endedAt ?? session.startedAt))"
        case .permission(let row):
            let times = Self.span(row.firstSeen, row.lastSeen)
            return row.accessor.isEmpty || row.accessor == row.app ? times : String(localized: "\(times), via \(row.accessor)")
        case .admin(let row):
            let times = Self.span(row.firstSeen, row.lastSeen)
            let client = (row.client as NSString).lastPathComponent
            return row.client == row.app ? times : String(localized: "\(times), via \(client)")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch event {
        case .sensor(let session):
            Text(session.isActive ? String(localized: "Active") : Formatting.duration(session.duration()))
                .monospacedDigit()
                .foregroundStyle(session.isActive ? Color.orange : Color.secondary)
        case .permission(let row):
            HStack(spacing: 8) {
                Text(row.preflight ? String(localized: "\(row.resultName) (check)") : row.resultName)
                    .foregroundStyle(row.authValue == 0 ? Color.red : row.authValue == 2 ? Color.primary : Color.secondary)
                Text("×\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                if let url = ProtectedFolder.url(for: row.service) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(url.path) in Finder")
                    .accessibilityLabel("Open in Finder")
                }
            }
        case .admin(let row):
            Text("×\(row.count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// A day's checks: one time, or the first and the last.
    private static func span(_ first: Date, _ last: Date) -> String {
        let start = time(first), end = time(last)
        return start == end ? start : "\(start) – \(end)"
    }
}

/// A row that opens the activity window of its app when clicked.
struct AppActivityLink<Content: View>: View {
    let target: AppActivityTarget
    var showsChevron = true
    @ViewBuilder let content: Content
    @Environment(\.openAppActivityAction) private var open

    var body: some View {
        Button {
            open?(target)
        } label: {
            HStack(spacing: 6) {
                content
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show App Activity")
        .accessibilityHint("Shows everything this app did")
    }
}
