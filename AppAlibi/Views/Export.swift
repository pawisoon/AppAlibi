import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What File > Export… does in the focused history tab. Tabs without a table publish nothing.
struct ExportAction {
    let run: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var exportAction: ExportAction?
}

@MainActor
enum CSVSaver {
    /// Asks where to save, then writes UTF-8. Not sandboxed, so any folder works.
    static func save(suggestedName: String, contents: @escaping @MainActor () -> String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(suggestedName) \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try contents().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}
