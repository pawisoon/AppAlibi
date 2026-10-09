import AlibiKit
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.isSensitiveSensorActive ? "eye.fill" : "eye")
            .accessibilityLabel(model.isSensitiveSensorActive ? "AppAlibi, sensor in use" : "AppAlibi")
    }
}

struct MenuContentView: View {
    let model: AppModel
    @Environment(\.openMainWindowAction) private var openMainWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = model.storeError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            section("Active now") {
                if model.activeSessions.isEmpty {
                    placeholder(model.showSystemInMenu
                        ? "Nothing is using your camera, microphone or screen."
                        : "No app is using your camera, microphone or screen.")
                } else {
                    ForEach(model.activeSessions) { SessionRow(session: $0) }
                }
            }

            Divider()

            section("Recent") {
                if model.recentSessions.isEmpty {
                    placeholder("No activity recorded yet.")
                } else {
                    ForEach(model.recentSessions) { SessionRow(session: $0) }
                }
            }

            Divider()

            HStack {
                Button("History…") { openMainWindow?() }
                OpenSettingsButton { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("AppAlibi").font(.headline)
            Spacer()
            Label(model.statusText, systemImage: model.isFailed ? "exclamationmark.triangle.fill" : "circle.fill")
                .labelStyle(StatusLabelStyle(failed: model.isFailed))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

private struct StatusLabelStyle: LabelStyle {
    let failed: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: failed ? 10 : 6))
                .foregroundStyle(failed ? .orange : .green)
            configuration.title
        }
    }
}

struct SessionRow: View {
    let session: SensorSession

    var body: some View {
        let info = AppInfo.info(for: session.app)
        HStack(spacing: 8) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: session.sensor.symbolName)
                .foregroundStyle(session.isActive ? Color.orange : Color.secondary)
                .help(session.sensor.displayName)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if session.isActive {
            return "\(session.sensor.displayName) since \(Formatting.time(session.startedAt))"
        }
        return "\(session.sensor.displayName) · \(Formatting.time(session.startedAt)) · \(Formatting.duration(session.duration()))"
    }
}
