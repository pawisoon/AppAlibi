import AlibiKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps the user added in Settings as AI clients. Stored as JSON in UserDefaults.
struct CustomAIClient: Codable, Hashable, Identifiable {
    let name: String
    let bundleID: String?
    let path: String

    var client: AIClient { .custom(name: name, bundleID: bundleID, path: path) }
    var id: String { client.id }

    private static let key = "appalibi.ai.customClients"

    static func load() -> [CustomAIClient] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CustomAIClient].self, from: data)) ?? []
    }

    static func save(_ clients: [CustomAIClient]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(clients), forKey: key)
    }

    /// An app bundle, or any executable such as a CLI agent.
    @MainActor
    static func choose() -> CustomAIClient? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose an app or command-line tool to treat as an AI client.")
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = [.application, .unixExecutable, .executable]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bundle = url.pathExtension == "app" ? Bundle(url: url) : nil
        let name = FileManager.default.displayName(atPath: url.path)
        return CustomAIClient(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                              bundleID: bundle?.bundleIdentifier, path: url.path)
    }
}

/// Names and icons for AI clients.
@MainActor
enum AIClientInfo {
    private static var icons: [String: NSImage] = [:]

    /// `seen` is an identifier and binary the log logged for the client, used when no app is installed under its bundle IDs.
    static func icon(for client: AIClient, seen: (identifier: String, binaryPath: String)? = nil) -> NSImage {
        if let cached = icons[client.id] { return cached }
        let exact = client.bundleIDs.filter { !$0.hasSuffix("*") }
        let prefixes = client.bundleIDs.filter { $0.hasSuffix("*") }.map { String($0.dropLast()) }
        let candidates = exact + prefixes.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        var icon: NSImage?
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
                break
            }
        }
        if icon == nil, client.isCustom, let path = client.pathFragments.first, FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        }
        if icon == nil, let seen {
            let info = AppInfo.info(for: seen.identifier, binaryPath: seen.binaryPath.isEmpty ? nil : seen.binaryPath)
            icon = info.icon
        }
        guard let icon else {
            // Not cached: a later call with a logged binary can do better.
            return NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage()
        }
        icons[client.id] = icon
        return icon
    }
}

/// The control services an app or AI client was seen allowed, as small icons.
struct GrantBadges: View {
    let grants: [ObservedGrant]
    var adminSince: Date?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.badges(grants), id: \.symbol) { badge in
                Image(systemName: badge.symbol)
                    .font(.caption2)
                    .foregroundStyle(badge.symbol == Self.fullDiskSymbol ? Color.orange : Color.secondary)
                    .help(badge.help)
                    .accessibilityLabel(badge.help)
            }
            if let adminSince {
                Image(systemName: "person.badge.key.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Got administrator rights, last \(adminSince.formatted(date: .abbreviated, time: .shortened))"))
            }
        }
    }

    static let fullDiskSymbol = "internaldrive.fill"

    struct Badge {
        let symbol: String
        let help: String
    }

    /// One badge per kind of access, in a fixed order. Mouse and keyboard
    /// control covers both Accessibility and PostEvent.
    static func badges(_ grants: [ObservedGrant]) -> [Badge] {
        let allowed = grants.filter(\.isAllowed)
        func since(_ services: [String]) -> Date? {
            allowed.filter { services.contains($0.service) }.compactMap(\.firstAllowed).min()
        }
        let kinds: [(services: [String], symbol: String, name: String)] = [
            ([EventStore.fullDiskAccessService], fullDiskSymbol, String(localized: "Seen allowed Full Disk Access")),
            (["kTCCServiceAccessibility", "kTCCServicePostEvent"], "cursorarrow.click.2",
             String(localized: "Seen allowed to control mouse and keyboard")),
            (["kTCCServiceListenEvent"], "keyboard", String(localized: "Seen allowed Input Monitoring")),
            (["kTCCServiceScreenCapture"], "rectangle.dashed.badge.record", String(localized: "Seen allowed Screen Recording")),
            (["kTCCServiceAppleEvents"], "gearshape.2", String(localized: "Seen allowed to control other apps")),
        ]
        return kinds.compactMap { kind in
            guard let date = since(kind.services) else { return nil }
            let first = date.formatted(date: .abbreviated, time: .shortened)
            return Badge(symbol: kind.symbol, help: String(localized: "\(kind.name), first \(first)"))
        }
    }
}
