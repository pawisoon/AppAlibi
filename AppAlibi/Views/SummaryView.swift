import AlibiKit
import Charts
import SwiftUI

@MainActor
@Observable
final class SummaryTabState {
    var scope: AppScope = .apps
    var report: ActivityReport?
    var aiReport: AIReport?
    let loader = TabLoader()
}

/// A day or a week at a glance, laid out like Screen Time in System Settings:
/// the total, a bar per hour or day, then the apps behind it.
struct SummaryView: View {
    let model: AppModel
    @Bindable private var state: SummaryTabState

    init(model: AppModel) {
        self.model = model
        state = model.summaryTab
    }

    private var scope: AppScope { state.scope }

    private var period: ReportPeriod { model.summaryPeriod }
    private var interval: DateInterval { period.interval(containing: model.summaryDate) }
    private var isCurrent: Bool { interval.contains(Date()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScopePicker(scope: $state.scope)
                Picker("Period", selection: Binding(get: { model.summaryPeriod }, set: { model.summaryPeriod = $0 })) {
                    Text("Day").tag(ReportPeriod.day)
                    Text("Week").tag(ReportPeriod.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                LoadingIndicator(loader: state.loader)
                navigator
            }
            .padding(10)

            Form {
                if let report = state.report {
                    overview(report)
                    appsSection(report)
                    permissionsSection(report)
                }
                if scope != .system, let aiReport = state.aiReport {
                    aiSection(aiReport)
                }
            }
            .formStyle(.grouped)
            .tint(.orange)
        }
        .task(id: reloadKey) {
            let key = reloadKey
            let report = model.reportFetch(interval, bucket: period.bucket, scope: scope)
            let aiReport = model.aiReportFetch(interval)
            await state.loader.load(key, model: model,
                                    fetch: { store in (report: try report(store), ai: try aiReport(store)) },
                                    apply: { result in
                                        state.report = result.report
                                        state.aiReport = result.ai
                                    })
        }
    }

    private struct ReloadKey: Hashable {
        let sessions: Int
        let permissions: Int
        let admin: Int
        let clients: Int
        let period: ReportPeriod
        let start: Date
        let scope: AppScope
    }

    private var reloadKey: ReloadKey {
        ReloadKey(sessions: model.sessionsRevision, permissions: model.permissionsRevision,
                  admin: model.adminRightsRevision, clients: model.aiClientsRevision,
                  period: period, start: interval.start, scope: scope)
    }

    // MARK: Date navigation

    private var navigator: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help(period == .day ? Text("Previous day") : Text("Previous week"))
            Text(title)
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 150)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isCurrent)
                .help(period == .day ? Text("Next day") : Text("Next week"))
        }
        .buttonStyle(.borderless)
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = period == .day ? .day : .weekOfYear
        if let date = Calendar.current.date(byAdding: component, value: direction, to: model.summaryDate) {
            model.summaryDate = min(date, Date())
        }
    }

    private var title: String {
        let calendar = Calendar.current
        switch period {
        case .day:
            if calendar.isDateInToday(interval.start) { return String(localized: "Today") }
            if calendar.isDateInYesterday(interval.start) { return String(localized: "Yesterday") }
            return interval.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week:
            if isCurrent { return String(localized: "This Week") }
            let last = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    // MARK: Overview

    private func overview(_ report: ActivityReport) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    (period == .day ? Text("Camera, microphone or screen in use") : Text("Daily average"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(Self.long(period == .day ? report.activeTime : dailyAverage(report)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                if period == .week {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total").font(.subheadline).foregroundStyle(.secondary)
                        Text(Self.long(report.activeTime)).font(.title3.weight(.medium)).monospacedDigit()
                    }
                }
            }

            chart(report)
                .frame(height: 150)
                .padding(.vertical, 4)

            HStack(spacing: 20) {
                ForEach(Sensor.known.filter(\.isSensitive), id: \.self) { sensor in
                    Label {
                        Text(Self.short(report.total(for: sensor))).monospacedDigit()
                    } icon: {
                        Image(systemName: sensor.symbolName).foregroundStyle(.tint)
                    }
                    .help(sensor.displayName)
                }
                Spacer()
            }
            .font(.callout)
        }
    }

    private func chart(_ report: ActivityReport) -> some View {
        let unit: Calendar.Component = period == .day ? .hour : .day
        return Chart(report.timeline) { bucket in
            BarMark(
                x: .value("Time", bucket.interval.start, unit: unit),
                y: .value("Minutes", bucket.duration / 60)
            )
            .foregroundStyle(bucket.interval.contains(Date()) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.7)))
            .cornerRadius(3)
        }
        .chartXScale(domain: interval.start...interval.end)
        .chartXAxis {
            if period == .day {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(), anchor: .topLeading)
                }
            } else {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        minutes >= 60 ? Text("\(Int(minutes / 60))h") : Text("\(Int(minutes))m")
                    }
                }
            }
        }
        .chartYScale(domain: 0...max(period == .day ? 15 : 60, (report.timeline.map(\.duration).max() ?? 0) / 60))
        .accessibilityLabel(period == .day
            ? Text("Time with camera, microphone or screen in use, by hour")
            : Text("Time with camera, microphone or screen in use, by day"))
    }

    /// Over the days of the week that have started.
    private func dailyAverage(_ report: ActivityReport) -> TimeInterval {
        let days = max(1, report.timeline.filter { $0.interval.start <= Date() }.count)
        return report.activeTime / Double(days)
    }

    // MARK: Lists

    private func appsSection(_ report: ActivityReport) -> some View {
        Section("Camera, Microphone and Screen") {
            if report.apps.isEmpty {
                (scope == .system ? Text("No system service used them.") : Text("No app used them."))
                    .foregroundStyle(.secondary)
            } else {
                let longest = report.apps.first?.duration ?? 1
                ForEach(report.apps) { usage in
                    AppUsageRow(usage: usage, fraction: longest > 0 ? usage.duration / longest : 0)
                }
            }
        }
    }

    private func permissionsSection(_ report: ActivityReport) -> some View {
        Section {
            let groups = PermissionGroup.make(report.permissions)
            if groups.isEmpty {
                Text("Nothing reached for protected data.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { PermissionGroupRow(group: $0) }
            }
        } header: {
            Text("Protected Data")
        } footer: {
            Text("Real access checks only. Preflight checks, where an app asks whether it may without accessing anything, are left out.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func aiSection(_ report: AIReport) -> some View {
        Section {
            if report.clients.isEmpty {
                Text("No AI client was active.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.clients) { usage in
                    if let client = model.aiClient(id: usage.client) {
                        AIClientUsageRow(client: client, usage: usage)
                    }
                }
            }
        } header: {
            Text("AI Clients")
        } footer: {
            Text("Real access checks only. Details in the AI tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Formatting

    static func long(_ interval: TimeInterval) -> String {
        if interval <= 0 { return String(localized: "0m") }
        if interval < 60 { return String(localized: "<1m") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "\(Int(interval / 60))m"
    }

    static func short(_ interval: TimeInterval) -> String {
        interval == 0 ? "–" : long(interval)
    }
}

private struct AppUsageRow: View {
    let usage: ActivityReport.AppUsage
    let fraction: Double

    var body: some View {
        let info = AppInfo.info(for: usage.app)
        HStack(spacing: 10) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info.name).lineLimit(1)
                    ForEach(usage.sensors, id: \.self) { sensor in
                        Image(systemName: sensor.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(sensor.displayName)
                    }
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(4, proxy.size.width * fraction), height: 5)
                }
                .frame(height: 5)
            }
            Text(SummaryView.long(usage.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The permission rows of one app, folded together.
private struct PermissionGroup: Identifiable {
    let app: String
    let binaryPath: String
    let services: [String]
    let allowed: Int
    let denied: Int
    var id: String { app }

    static func make(_ rows: [ActivityReport.PermissionUsage]) -> [PermissionGroup] {
        var order: [String] = []
        var byApp: [String: [ActivityReport.PermissionUsage]] = [:]
        for row in rows {
            if byApp[row.app] == nil { order.append(row.app) }
            byApp[row.app, default: []].append(row)
        }
        return order.map { app in
            let rows = byApp[app]!
            return PermissionGroup(
                app: app,
                binaryPath: rows[0].binaryPath,
                services: rows.map(\.serviceName),
                allowed: rows.reduce(0) { $0 + $1.allowed },
                denied: rows.reduce(0) { $0 + $1.denied }
            )
        }
    }
}

private struct PermissionGroupRow: View {
    let group: PermissionGroup

    var body: some View {
        let info = AppInfo.info(for: group.app, binaryPath: group.binaryPath.isEmpty ? nil : group.binaryPath)
        HStack(spacing: 10) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).lineLimit(1)
                Text(ListFormatter.localizedString(byJoining: group.services))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if group.allowed > 0 {
                    Text("Allowed: \(group.allowed)").monospacedDigit()
                }
                if group.denied > 0 {
                    Text("Denied: \(group.denied)").monospacedDigit().foregroundStyle(.red)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct AIClientUsageRow: View {
    let client: AIClient
    let usage: AIReport.ClientUsage

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AIClientInfo.icon(for: client))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).lineLimit(1)
                if !usage.newAccess.isEmpty {
                    Text("New: \(ListFormatter.localizedString(byJoining: usage.newAccess.map(TCCService.displayName(for:))))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    ForEach(usage.sensors, id: \.sensor) { item in
                        Label {
                            Text(SummaryView.long(item.duration)).monospacedDigit()
                        } icon: {
                            Image(systemName: item.sensor.symbolName)
                        }
                        .help(item.sensor.displayName)
                    }
                }
                if usage.checks > 0 {
                    Text("Checks: \(usage.checks)").monospacedDigit().foregroundStyle(.secondary)
                }
                if usage.adminGrants > 0 {
                    Text("Admin rights: \(usage.adminGrants)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
