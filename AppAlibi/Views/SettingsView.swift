import AlibiKit
import SwiftUI

/// Settings in tabs, like System Settings panes in other Mac apps: one short
/// page per topic instead of one long form.
struct SettingsView: View {
    let model: AppModel

    enum Pane: String, CaseIterable {
        case general, alerts, summaries, aiClients, history
    }

    @AppStorage("appalibi.settings.pane") private var pane: Pane = .general

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)
            AlertSettingsPane()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
                .tag(Pane.alerts)
            SummarySettingsPane()
                .tabItem { Label("Summaries", systemImage: "chart.bar.xaxis") }
                .tag(Pane.summaries)
            AIClientSettings(model: model)
                .tabItem { Label("AI Clients", systemImage: "sparkles") }
                .tag(Pane.aiClients)
            HistorySettings(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Pane.history)
        }
        .frame(width: 600)
    }
}

/// Every pane is a grouped form as tall as its content, so the window
/// resizes to the pane.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let model: AppModel

    @AppStorage(MacPreferences.presentationKey) private var presentation: MacPresentation = .menuBar
    @Environment(\.showOnboardingAction) private var showOnboardingAction
    @State private var opensAtLogin = MacPreferences.opensAtLogin

    var body: some View {
        SettingsPane {
            Section {
                Picker("Show AppAlibi in", selection: $presentation) {
                    ForEach(MacPresentation.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $opensAtLogin) {
                    Text("Open at login")
                    Text("Keeps the record going from the moment you log in.")
                }
                .onChange(of: opensAtLogin) { _, value in
                    MacPreferences.setOpensAtLogin(value)
                    opensAtLogin = MacPreferences.opensAtLogin
                }
            }

            Section("Menu") {
                Toggle(isOn: Binding(get: { model.showSystemInMenu }, set: { model.setShowSystemInMenu($0) })) {
                    Text("Show system services")
                    Text("Apple background services, such as screenshots taken by the system.")
                }
                Toggle(isOn: Binding(get: { model.showLocation }, set: { model.setShowLocation($0) })) {
                    Text("Show location")
                    Text("Off by default because macOS checks your location every few minutes.")
                }
            }

            Section {
                if let showOnboardingAction {
                    Button("Show Welcome Tour Again", action: showOnboardingAction)
                }
                Text("Everything stays on this Mac and there is no account. AppAlibi reads the macOS log and never sends it anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { opensAtLogin = MacPreferences.opensAtLogin }
    }
}

// MARK: - Notifications

/// Asks for notification permission once something that notifies is on.
@MainActor
private func askForNotificationsIfNeeded() {
    guard AlertPreferences.wantsNotifications else { return }
    Task { await Notifier.shared.requestAuthorization() }
}

/// Shown on both notification panes while the system blocks AppAlibi's notifications.
private struct NotificationsDeniedSection: View {
    private let notifier = Notifier.shared

    var body: some View {
        if notifier.isDenied {
            Section {
                HStack {
                    Label("Notifications are turned off for AppAlibi.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open System Settings") { notifier.openSystemSettings() }
                }
                .font(.callout)
            }
        }
    }
}

private struct AlertSettingsPane: View {
    @AppStorage(AlertPreferences.sensorsKey) private var sensorAlerts: SensorAlertMode = .off
    @AppStorage(AlertPreferences.firstPermissionKey) private var permissionAlerts = false
    @AppStorage(AlertPreferences.lockedUseKey) private var lockedUseAlerts = false
    @AppStorage(AlertPreferences.adminRightsKey) private var adminRightAlerts = false
    @AppStorage(AlertPreferences.aiClientsKey) private var aiClientAlerts = false
    @AppStorage(AlertPreferences.fullDiskAccessKey) private var fullDiskAccessAlerts = false

    var body: some View {
        SettingsPane {
            NotificationsDeniedSection()

            Section {
                Picker(selection: $sensorAlerts) {
                    ForEach(SensorAlertMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Camera, microphone or screen")
                    Text("When an app starts using one. System services are left out.")
                }
                Toggle(isOn: $lockedUseAlerts) {
                    Text("Use while the screen is locked")
                    Text("Told when you unlock, system services included.")
                }
            } header: {
                Text("Sensors")
            }

            Section {
                Toggle(isOn: $permissionAlerts) {
                    Text("First access to protected data")
                    Text("When an app first reaches for your folders, contacts, photos and so on.")
                }
                Toggle(isOn: $fullDiskAccessAlerts) {
                    Text("Full Disk Access")
                    Text("The first time macOS lets an app read all your files.")
                }
                Toggle(isOn: $adminRightAlerts) {
                    Text("Administrator rights")
                    Text("Every time an app is allowed to install software or make other changes that need an admin password.")
                }
                Toggle(isOn: $aiClientAlerts) {
                    Text("AI clients")
                    Text("First control of the mouse, keyboard, screen or files, admin rights, and use while locked.")
                }
            } header: {
                Text("Access")
            }
        }
        .task { await Notifier.shared.refreshStatus() }
        .onChange(of: sensorAlerts) { askForNotificationsIfNeeded() }
        .onChange(of: permissionAlerts) { askForNotificationsIfNeeded() }
        .onChange(of: lockedUseAlerts) { askForNotificationsIfNeeded() }
        .onChange(of: adminRightAlerts) { askForNotificationsIfNeeded() }
        .onChange(of: aiClientAlerts) { askForNotificationsIfNeeded() }
        .onChange(of: fullDiskAccessAlerts) { askForNotificationsIfNeeded() }
    }
}

private struct SummarySettingsPane: View {
    @AppStorage(AlertPreferences.dailyKey) private var dailySummary = false
    @AppStorage(AlertPreferences.weeklyKey) private var weeklySummary = false
    @AppStorage(AlertPreferences.minuteKey) private var summaryMinute = AlertPreferences.defaultMinute
    @AppStorage(AlertPreferences.weekdayKey) private var summaryWeekday = AlertPreferences.defaultWeekday

    var body: some View {
        SettingsPane {
            NotificationsDeniedSection()

            Section {
                Toggle(isOn: $dailySummary) {
                    Text("Daily summary")
                    Text("Which apps used your camera, microphone and screen today.")
                }
                Toggle("Weekly summary", isOn: $weeklySummary)
                if weeklySummary {
                    Picker("Weekly on", selection: $summaryWeekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                if dailySummary || weeklySummary {
                    DatePicker("Summary time", selection: summaryTime, displayedComponents: .hourAndMinute)
                }
            } footer: {
                if dailySummary || weeklySummary {
                    HStack {
                        Spacer()
                        Button("Send Today\u{2019}s Summary Now") { ReportScheduler.shared.send(.day) }
                    }
                }
            }
        }
        .task { await Notifier.shared.refreshStatus() }
        .onChange(of: dailySummary) { _, on in summaryToggled(.day, on: on) }
        .onChange(of: weeklySummary) { _, on in summaryToggled(.week, on: on) }
    }

    /// Minutes after midnight, edited as a time of day.
    private var summaryTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: summaryMinute / 60, minute: summaryMinute % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                summaryMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func summaryToggled(_ period: ReportPeriod, on: Bool) {
        // Counts from now: switching on at 19:00 does not send the 18:00 summary at once.
        if on { AlertPreferences.setLastDelivered(Date(), for: period) }
        askForNotificationsIfNeeded()
    }
}

// MARK: - AI clients

private struct AIClientSettings: View {
    let model: AppModel
    @State private var selection: CustomAIClient.ID?

    var body: some View {
        SettingsPane {
            Section {
                Text(ListFormatter.localizedString(byJoining: AIClientCatalog.builtIn.clients.map(\.name)))
            } header: {
                Text("Recognized Automatically")
            } footer: {
                Text("Matched by bundle ID or by where the app or tool is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                List(selection: $selection) {
                    ForEach(model.customAIClients) { client in
                        HStack {
                            Image(nsImage: AIClientInfo.icon(for: client.client))
                                .resizable()
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(client.name)
                                Text(client.bundleID ?? client.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .tag(client.id)
                    }
                }
                .frame(minHeight: 90)
                .overlay {
                    if model.customAIClients.isEmpty {
                        Text("None yet")
                            .foregroundStyle(.secondary)
                    }
                }
                .onDeleteCommand(perform: removeSelected)
                // The add and remove buttons under a list, as in Login Items.
                HStack(spacing: 0) {
                    Button {
                        if let client = CustomAIClient.choose() { model.addCustomAIClient(client) }
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("Add an app or command-line tool")
                    Divider().frame(height: 16)
                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .disabled(selection == nil)
                    .help("Remove the selected one")
                    Spacer()
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Also Treat as AI")
            } footer: {
                Text("Add an app or command-line tool AppAlibi does not know. Its earlier history is included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func removeSelected() {
        guard let client = model.customAIClients.first(where: { $0.id == selection }) else { return }
        model.removeCustomAIClient(client)
        selection = nil
    }
}

// MARK: - History

private struct HistorySettings: View {
    let model: AppModel

    @State private var confirmDelete = false
    /// A shorter retention waiting for the user to confirm the deletion it causes.
    @State private var pendingRetention: HistoryRetention?

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent("Status", value: model.statusText)
                Picker(selection: retention) {
                    ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Keep history")
                    Text("Older history is deleted from this Mac.")
                }
                LabeledContent("Database") {
                    Button("Show in Finder") { model.revealDatabase() }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Delete History…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("Delete all recorded history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) { model.deleteHistory() }
        } message: {
            Text("Sensor sessions, permission checks, admin rights, AI client history and screen locks are removed from this Mac. This cannot be undone.")
        }
        .confirmationDialog(
            "Keep history for \((pendingRetention ?? .forever).duration)?",
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })
        ) {
            Button("Delete Older History", role: .destructive) {
                if let pendingRetention { model.setRetention(pendingRetention) }
                pendingRetention = nil
            }
        } message: {
            Text("History older than that is deleted now, and from then on as it ages. This cannot be undone.")
        }
    }

    /// A shorter setting deletes history, so it waits for confirmation.
    private var retention: Binding<HistoryRetention> {
        Binding(
            get: { model.retention },
            set: { value in
                if model.retention.isLonger(than: value) {
                    pendingRetention = value
                } else {
                    model.setRetention(value)
                }
            }
        )
    }
}
