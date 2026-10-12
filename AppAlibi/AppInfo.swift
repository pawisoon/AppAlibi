import AlibiKit
import AppKit

/// Resolves bundle IDs and binary paths to a display name, icon and kind.
/// Control Center logs bundle IDs only; names and paths are redacted.
@MainActor
enum AppInfo {
    struct Info {
        let name: String
        let icon: NSImage
        let kind: AppKind
    }

    private static var cache: [String: Info] = [:]
    /// Kinds on their own: the scope filters classify every identifier in the
    /// database and need no name or icon, and loading icons is the slow part.
    private static var kinds: [String: AppKind] = [:]

    static func info(for identifier: String, binaryPath: String? = nil) -> Info {
        let key = identifier + "|" + (binaryPath ?? "")
        if let cached = cache[key] { return cached }
        let info = lookup(identifier, binaryPath: binaryPath)
        cache[key] = info
        kinds[key] = info.kind
        return info
    }

    static func kind(for identifier: String, binaryPath: String? = nil) -> AppKind {
        let key = identifier + "|" + (binaryPath ?? "")
        if let kind = kinds[key] { return kind }
        let path = binaryPath?.isEmpty == false ? binaryPath : nil
        let bundleURL = bundleURL(for: identifier, binaryPath: path)
        let kind = AppClassifier.kind(identifier: identifier, bundlePath: bundleURL?.path, binaryPath: path)
        kinds[key] = kind
        return kind
    }

    private static func bundleURL(for identifier: String, binaryPath path: String?) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) ?? path.flatMap(enclosingAppBundle(of:))
    }

    private static func lookup(_ identifier: String, binaryPath: String?) -> Info {
        let path = binaryPath?.isEmpty == false ? binaryPath : nil
        let bundleURL = bundleURL(for: identifier, binaryPath: path)
        let kind = AppClassifier.kind(identifier: identifier, bundlePath: bundleURL?.path, binaryPath: path)

        if let bundleURL {
            return Info(name: displayName(of: bundleURL), icon: NSWorkspace.shared.icon(forFile: bundleURL.path), kind: kind)
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            return Info(name: identifier, icon: NSWorkspace.shared.icon(forFile: path), kind: kind)
        }
        let symbol = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil) ?? NSImage()
        return Info(name: identifier, icon: symbol, kind: kind)
    }

    private static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// `/Applications/Foo.app/Contents/MacOS/Foo` -> `/Applications/Foo.app` (outermost bundle).
    private static func enclosingAppBundle(of path: String) -> URL? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
    }
}

/// Which kinds of app a list shows.
enum AppScope: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case system = "System"
    case all = "All"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .apps: "Apps"
        case .system: "System"
        case .all: "All"
        }
    }

    var kind: AppKind? {
        switch self {
        case .apps: .app
        case .system: .system
        case .all: nil
        }
    }
}
