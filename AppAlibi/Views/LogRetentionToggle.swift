import AlibiKit
import Foundation
import SwiftUI

/// Settings row for `LogRetention`. Changing it asks for an administrator
/// password, since macOS logging preferences belong to root.
struct LogRetentionToggle: View {
    @State private var isOn = LogRetention.isEnabled()
    @State private var failure: String?

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: change)) {
            // LogRetention.days is 14.
            Text("Keep the macOS log for two weeks")
            Text("macOS can drop the log AppAlibi reads within a day, so time when AppAlibi isn't running goes unrecorded. This asks macOS to keep the lines AppAlibi reads for two weeks, so it can fill in the gaps at its next launch. Needs an administrator password.")
        }
        .onAppear { isOn = LogRetention.isEnabled() }
        .alert("Could not change the macOS log settings", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func change(_ value: Bool) {
        if case .failed(let message) = LogRetentionInstaller.set(enabled: value) { failure = message }
        isOn = LogRetention.isEnabled()
    }
}

/// Writes `LogRetention`'s preference files as root.
@MainActor
enum LogRetentionInstaller {
    enum Outcome: Equatable {
        case done, cancelled
        case failed(String)
    }

    /// Shows the system's administrator password prompt and blocks until it
    /// is answered. NSAppleScript has to run on the main thread.
    static func set(enabled: Bool) -> Outcome {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppAlibi-logging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let changes = try LogRetention.changes(enable: enabled)
            guard !changes.isEmpty else { return .done }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var staged: [(change: LogRetention.FileChange, staged: URL?)] = []
            for change in changes {
                guard let contents = change.contents else {
                    staged.append((change, nil))
                    continue
                }
                let url = staging.appendingPathComponent(change.url.lastPathComponent)
                try contents.write(to: url)
                staged.append((change, url))
            }
            return run(asAdministrator: LogRetention.script(installing: staged))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func run(asAdministrator script: String) -> Outcome {
        let literal = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let source = "do shell script \"\(literal)\" with administrator privileges"
        var info: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return .failed(source) }
        appleScript.executeAndReturnError(&info)
        guard let info else { return .done }
        // userCanceledErr: the user pressed Cancel.
        if info[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
        return .failed(info[NSAppleScript.errorMessage] as? String ?? String(describing: info))
    }
}
