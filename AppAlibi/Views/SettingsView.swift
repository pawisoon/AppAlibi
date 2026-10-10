import AlibiKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @AppStorage(MacPreferences.presentationKey) private var presentation: MacPresentation = .menuBar
    @Environment(\.showOnboardingAction) private var showOnboardingAction
    @State private var opensAtLogin = MacPreferences.opensAtLogin
    @State private var confirmDelete = false
    /// A shorter retention waiting for the user to confirm the deletion it causes.
    @State private var pendingRetention: HistoryRetention?
    @AppStorage(AlertPreferences.sensorsKey) private var sensorAlerts: SensorAlertMode = .off
    @AppStorage(AlertPreferences.firstPermissionKey) private var permissionAlerts = false
    @AppStorage(AlertPreferences.lockedUseKey) private var lockedUseAlerts = false
    @AppStorage(AlertPreferences.adminRightsKey) private var adminRightAlerts = false
    @AppStorage(AlertPreferences.dailyKey) private var dailySummary = false
    @AppStorage(AlertPreferences.weeklyKey) private var weeklySummary = false
    @AppStorage(AlertPreferences.minuteKey) private var summaryMinute = AlertPreferences.defaultMinute
    @AppStorage(AlertPreferences.weekdayKey) private var summaryWeekday = AlertPreferences.defaultWeekday
    private let notifier = Notifier.shared

    var body: some View {
        Form {
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

            Section {
                Toggle(isOn: Binding(get: { model.showSystemInMenu }, set: { model.setShowSystemInMenu($0) })) {
                    Text("Show system services")
                    Text("Apple background services, such as screenshots taken by the system.")
                }
                Toggle(isOn: Binding(get: { model.showLocation }, set: { model.setShowLocation($0) })) {
                    Text("Show location")
                    Text("Off by default because macOS checks your location every few minutes.")
                }
            } header: {
                Text("Menu")
            }

            notificationsSection

            Section("History") {
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
                Button("Delete History…", role: .destructive) { confirmDelete = true }
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
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { opensAtLogin = MacPreferences.opensAtLogin }
        .task { await notifier.refreshStatus() }
        .confirmationDialog("Delete all recorded history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) { model.deleteHistory() }
        } message: {
            Text("Sensor sessions, permission checks, admin rights and screen locks are removed from this Mac. This cannot be undone.")
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

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            Picker(selection: $sensorAlerts) {
                ForEach(SensorAlertMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Camera, microphone or screen")
                Text("When an app starts using one. System services are left out.")
            }
            Toggle(isOn: $permissionAlerts) {
                Text("First access to protected data")
                Text("When an app first reaches for your folders, contacts, photos and so on.")
            }
            Toggle(isOn: $lockedUseAlerts) {
                Text("Use while the screen is locked")
                Text("When you unlock: anything that used the camera, microphone or screen while you were away, system services included.")
            }
            Toggle(isOn: $adminRightAlerts) {
                Text("Administrator rights")
                Text("Every time an app is allowed to install software or make other changes that need an admin password.")
            }

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
                HStack {
                    Spacer()
                    Button("Send Today\u{2019}s Summary Now") { ReportScheduler.shared.send(.day) }
                }
            }

            if notifier.isDenied {
                HStack {
                    Label("Notifications are turned off for AppAlibi.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open System Settings") { notifier.openSystemSettings() }
                }
                .font(.callout)
            }
        } header: {
            Text("Notifications")
        }
        .onChange(of: sensorAlerts) { askIfNeeded() }
        .onChange(of: permissionAlerts) { askIfNeeded() }
        .onChange(of: lockedUseAlerts) { askIfNeeded() }
        .onChange(of: adminRightAlerts) { askIfNeeded() }
        .onChange(of: dailySummary) { _, on in summaryToggled(.day, on: on) }
        .onChange(of: weeklySummary) { _, on in summaryToggled(.week, on: on) }
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
        askIfNeeded()
    }

    private func askIfNeeded() {
        guard AlertPreferences.wantsNotifications else { return }
        Task { await notifier.requestAuthorization() }
    }
}
