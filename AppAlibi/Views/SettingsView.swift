import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @AppStorage(MacPreferences.presentationKey) private var presentation: MacPresentation = .menuBar
    @Environment(\.showOnboardingAction) private var showOnboardingAction
    @State private var opensAtLogin = MacPreferences.opensAtLogin
    @State private var confirmDelete = false

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

            Section("History") {
                LabeledContent("Status", value: model.statusText)
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
        .confirmationDialog("Delete all recorded history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) { model.deleteHistory() }
        } message: {
            Text("Sensor sessions and permission checks are removed from this Mac. This cannot be undone.")
        }
    }
}
