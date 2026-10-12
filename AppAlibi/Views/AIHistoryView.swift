import AlibiKit
import SwiftUI

@MainActor
@Observable
final class AITabState {
    /// An `AIClient` ID, or nil for every client.
    var client: String?
    var kind: AIActivity.Kind?
    var range: TimeRange = .week
    var realOnly = true
    var activities: [AIActivity] = []
    var grants: [String: [ObservedGrant]] = [:]
    var admin: [String: Date] = [:]
    let loader = TabLoader()
}

/// What each AI assistant and coding agent did: sensors, permission checks and
/// admin grants, from data the other tabs already record.
struct AIHistoryView: View {
    let model: AppModel
    @Bindable private var state: AITabState

    init(model: AppModel) {
        self.model = model
        state = model.aiTab
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Client", selection: $state.client) {
                    Text("All").tag(String?.none)
                    ForEach(pickerClients) { Text($0.name).tag(String?.some($0.id)) }
                }
                .frame(width: 220)
                Picker("Kind", selection: $state.kind) {
                    Text("All").tag(AIActivity.Kind?.none)
                    ForEach(AIActivity.Kind.allCases, id: \.self) { Text($0.title).tag(AIActivity.Kind?.some($0)) }
                }
                .frame(width: 180)
                Picker("Range", selection: $state.range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 160)
                Toggle("Real access only", isOn: $state.realOnly)
                    .toggleStyle(.checkbox)
                    .help("Hides preflight checks, where an app asks whether it may without accessing anything.")
                Spacer()
                LoadingIndicator(loader: state.loader)
                Button("Export\u{2026}", action: export)
                    .disabled(state.activities.isEmpty)
            }
            .padding(10)

            if !strip.isEmpty {
                clientStrip
                Divider()
            }

            Table(state.activities) {
                TableColumn("Time") { activity in
                    HStack(spacing: 4) {
                        Text(activity.time.formatted(date: .abbreviated, time: .shortened))
                        if activity.whileLocked {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .help("While the screen was locked")
                                .accessibilityLabel("While the screen was locked")
                        }
                    }
                }
                .width(min: 130, ideal: 160)
                TableColumn("Client") { activity in
                    clientLabel(activity.client, seen: (activity.app, activity.binaryPath))
                }
                .width(min: 120, ideal: 150)
                TableColumn("What") { activity in
                    WhatCell(activity: activity)
                }
                .width(min: 220, ideal: 320)
                TableColumn("Result") { activity in
                    resultText(activity)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Via") { activity in
                    Text(via(activity) ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(activity.binaryPath.isEmpty ? activity.app : activity.binaryPath)
                }
                .width(min: 100, ideal: 160)
            }
            .overlay {
                if state.activities.isEmpty && !state.loader.isLoading {
                    ContentUnavailableView("No AI Activity", systemImage: "sparkles",
                                           description: Text("No AI client used the camera, microphone or screen, or asked for access, in this range. Add your own in Settings."))
                }
            }
        }
        .focusedSceneValue(\.exportAction, ExportAction(run: export))
        .task(id: reloadKey) { await reload(reloadKey) }
    }

    // MARK: Client strip

    private struct StripItem: Identifiable {
        let client: AIClient
        let last: Date
        let seen: (identifier: String, binaryPath: String)
        var id: String { client.id }
    }

    /// One card per client seen in the range, most recent first.
    private var strip: [StripItem] {
        var items: [String: StripItem] = [:]
        for activity in state.activities {
            guard items[activity.client] == nil, let client = model.aiClient(id: activity.client) else { continue }
            items[activity.client] = StripItem(client: client, last: activity.time, seen: (activity.app, activity.binaryPath))
        }
        if let selected = state.client, items[selected] == nil, let client = model.aiClient(id: selected) {
            items[selected] = StripItem(client: client, last: .distantPast, seen: (selected, ""))
        }
        return items.values.sorted { $0.last > $1.last }
    }

    private var clientStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(strip) { item in
                    Button {
                        state.client = state.client == item.id ? nil : item.id
                    } label: {
                        ClientCard(item: item, grants: state.grants[item.id] ?? [], admin: state.admin[item.id],
                                   isSelected: state.client == item.id)
                    }
                    .buttonStyle(.plain)
                    .help(state.client == item.id ? Text("Show every client") : Text("Show only \(item.client.name)"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private struct ClientCard: View {
        let item: StripItem
        let grants: [ObservedGrant]
        let admin: Date?
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 8) {
                Image(nsImage: AIClientInfo.icon(for: item.client, seen: item.seen))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.client.name).font(.callout.weight(.medium)).lineLimit(1)
                    if item.last > .distantPast {
                        Text(item.last, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GrantBadges(grants: grants, adminSince: admin)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Every client the catalog knows, so a filter can be picked before it has activity.
    private var pickerClients: [AIClient] {
        model.aiCatalog.clients
    }

    // MARK: Cells

    private func clientLabel(_ id: String, seen: (String, String)) -> some View {
        let client = model.aiClient(id: id)
        return HStack(spacing: 6) {
            if let client {
                Image(nsImage: AIClientInfo.icon(for: client, seen: seen))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(client?.name ?? id).lineLimit(1)
        }
    }

    @ViewBuilder
    private func resultText(_ activity: AIActivity) -> some View {
        switch activity.kind {
        case .sensor:
            if activity.end == nil {
                Text("Active").foregroundStyle(.orange)
            } else {
                Text(Formatting.duration(activity.duration())).monospacedDigit()
            }
        case .admin:
            Text("Granted")
        case .permission:
            Text(activity.resultName ?? "")
                .foregroundStyle(activity.isDenied ? Color.red : activity.isAllowed ? Color.primary : Color.secondary)
        }
    }

    /// The process that did it when it is not the client's own app: "git", "sandboxd".
    private func via(_ activity: AIActivity) -> String? {
        switch activity.kind {
        case .sensor:
            return nil
        case .admin:
            guard activity.accessor != activity.app else { return nil }
            return (activity.accessor as NSString).lastPathComponent
        case .permission:
            let client = model.aiClient(id: activity.client)
            // The executable's own name: git inside Xcode is "git", not "Xcode".
            if !activity.accessor.isEmpty, activity.accessor != activity.app {
                return activity.binaryPath.isEmpty ? activity.accessor : (activity.binaryPath as NSString).lastPathComponent
            }
            // A terminal or other app was blamed, and the client was found by its binary.
            if let client, !client.matches(identifier: activity.app) {
                return AppInfo.info(for: activity.app).name
            }
            return nil
        }
    }

    private struct WhatCell: View {
        let activity: AIActivity

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(activity.what).lineLimit(1)
                    if activity.isFirstTime {
                        Tag(text: Text("First time"), color: .orange)
                    }
                    if activity.isProbablyComputerUse {
                        Tag(text: Text("Probably computer use"), color: .purple)
                            .help("A screen recording that came with a check for control of the mouse and keyboard.")
                    }
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(activity.detail)
        }

        /// How many checks the row folds together, and over what time.
        private var detail: String? {
            guard activity.kind != .sensor else { return nil }
            var parts: [String] = []
            if activity.count > 1 { parts.append(String(localized: "Times: \(activity.count)")) }
            if let end = activity.end, end.timeIntervalSince(activity.start) >= 60 {
                parts.append("\(Formatting.time(activity.start))\u{2013}\(Formatting.time(end))")
            }
            if activity.approximate { parts.append(String(localized: "approximate, from daily totals")) }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        }
    }

    private struct Tag: View {
        let text: Text
        let color: Color

        var body: some View {
            text
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(color)
                .background(color.opacity(0.15), in: Capsule())
        }
    }

    // MARK: Loading

    private struct ReloadKey: Hashable {
        let sessions: Int
        let permissions: Int
        let admin: Int
        let locks: Int
        let clients: Int
        let client: String?
        let kind: AIActivity.Kind?
        let range: TimeRange
        let realOnly: Bool
    }

    private var reloadKey: ReloadKey {
        ReloadKey(sessions: model.sessionsRevision, permissions: model.permissionsRevision,
                  admin: model.adminRightsRevision, locks: model.screenLocksRevision, clients: model.aiClientsRevision,
                  client: state.client, kind: state.kind, range: state.range, realOnly: state.realOnly)
    }

    private func query(limit: Int) -> AITimelineQuery {
        AITimelineQuery(clients: state.client.map { [$0] }, kinds: state.kind.map { [$0] },
                        includePreflight: !state.realOnly, since: state.range.since, limit: limit)
    }

    private func reload(_ key: ReloadKey) async {
        let timelineQuery = query(limit: 2_000)
        let catalog = model.aiCatalog
        let since = state.range.since
        await state.loader.load(key, model: model, fetch: { store in
            let locks = AppModel.screenLocks(store, since: since)
            return (activities: try AITimeline.build(store: store, catalog: catalog, query: timelineQuery, locks: locks),
                    grants: try store.aiObservedGrants(), admin: try store.aiAdminClients())
        }, apply: { result in
            state.activities = result.activities
            state.grants = result.grants
            state.admin = result.admin
        })
    }

    /// The same filters as the table, without its row limit.
    private func export() {
        CSVSaver.save(suggestedName: String(localized: "AppAlibi AI Clients")) {
            guard let store = model.store else { return "" }
            let locks = AppModel.screenLocks(store, since: nil)
            let rows = (try? AITimeline.build(store: store, catalog: model.aiCatalog, query: query(limit: .max), locks: locks)) ?? []
            return CSVExport.aiActivity(rows, client: { model.aiClient(id: $0)?.name ?? $0 }) { identifier, binaryPath in
                AppInfo.info(for: identifier, binaryPath: binaryPath.isEmpty ? nil : binaryPath).name
            }
        }
    }
}

extension AIActivity.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .sensor: "Sensors"
        case .permission: "Permissions"
        case .admin: "Admin rights"
        }
    }
}
