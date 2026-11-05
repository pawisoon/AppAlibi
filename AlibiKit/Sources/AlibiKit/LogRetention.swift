import Foundation

/// Asks macOS to keep the log lines AppAlibi reads for longer.
///
/// The main log store is capped by size, so on a busy Mac it holds less than a
/// day. Whatever happened while AppAlibi was not running is gone before the
/// next launch can catch up. Messages given a time to live go to a separate
/// store and stay that long, space permitting: Apple ships TTLs for some of its
/// own subsystems in /System/Library/Preferences/Logging/Subsystems.
///
/// Turning this on writes a TTL for each source's category to
/// /Library/Preferences/Logging/Subsystems, which takes root. Status is read
/// from the same files, which anyone can read.
public enum LogRetention {
    public struct Source: Hashable, Sendable {
        public let subsystem: String
        public let category: String
    }

    /// Where the lines in `LogPredicates` come from. Not loginwindow's
    /// screen locks: Apple already gives com.apple.loginwindow.logging a 5 day
    /// TTL, and a file of ours could get in the way of the rest of Apple's
    /// settings for it, such as its public privacy level.
    public static let sources: [Source] = [
        Source(subsystem: "com.apple.controlcenter", category: "sensor-indicators"),
        Source(subsystem: "com.apple.TCC", category: "access"),
        Source(subsystem: "com.apple.Authorization", category: "authd")
    ]

    /// logd sorts TTLs into 1, 3, 7, 14 and 30 days.
    public static let days = 14

    public static let directory = URL(fileURLWithPath: "/Library/Preferences/Logging/Subsystems", isDirectory: true)

    /// Posted to make logd read its preferences again.
    static let preferencesChanged = "com.apple.system.logging.prefschanged"

    /// One preference file after the change. nil contents: delete the file.
    public struct FileChange: Equatable, Sendable {
        public let url: URL
        public let contents: Data?
    }

    /// True when every source keeps its lines at least `days`.
    public static func isEnabled(in directory: URL = directory) -> Bool {
        sources.allSatisfy { source in
            let plist = read(directory.appendingPathComponent(source.subsystem + ".plist"))
            return ttl(of: source.category, in: plist).map { $0 >= days } ?? false
        }
    }

    /// The preference files to write, one per subsystem that needs a change.
    /// Settings already in the files are kept.
    public static func changes(enable: Bool, in directory: URL = directory) throws -> [FileChange] {
        try sources.compactMap { source in
            let url = directory.appendingPathComponent(source.subsystem + ".plist")
            let old = read(url)
            let new = enable ? enabling(source.category, in: old) : disabling(source.category, in: old)
            guard !NSDictionary(dictionary: new).isEqual(to: old) else { return nil }
            if new.isEmpty { return FileChange(url: url, contents: nil) }
            let data = try PropertyListSerialization.data(fromPropertyList: new, format: .xml, options: 0)
            return FileChange(url: url, contents: data)
        }
    }

    /// The shell commands that put the files in place, run as root. Each
    /// staged file is a copy of a change's contents in a temporary place.
    public static func script(installing changes: [(change: FileChange, staged: URL?)]) -> String {
        var lines = ["set -e", "/bin/mkdir -p \(quoted(directory.path))"]
        for (change, staged) in changes {
            if let staged {
                lines.append("/usr/bin/install -m 644 -o root -g wheel \(quoted(staged.path)) \(quoted(change.url.path))")
            } else {
                lines.append("/bin/rm -f \(quoted(change.url.path))")
            }
        }
        lines.append("/usr/bin/notifyutil -p \(preferencesChanged)")
        return lines.joined(separator: "\n")
    }

    // MARK: Plist editing

    static func enabling(_ category: String, in plist: [String: Any]) -> [String: Any] {
        var plist = plist
        var settings = plist[category] as? [String: Any] ?? [:]
        var ttl = settings["TTL"] as? [String: Any] ?? [:]
        if let current = ttl["Default"] as? Int, current >= days { return plist }
        ttl["Default"] = days
        settings["TTL"] = ttl
        plist[category] = settings
        return plist
    }

    /// Removes only the TTL this type wrote, so a longer one set by hand stays.
    static func disabling(_ category: String, in plist: [String: Any]) -> [String: Any] {
        var plist = plist
        guard var settings = plist[category] as? [String: Any],
              var ttl = settings["TTL"] as? [String: Any],
              ttl["Default"] as? Int == days else { return plist }
        ttl["Default"] = nil
        settings["TTL"] = ttl.isEmpty ? nil : ttl
        plist[category] = settings.isEmpty ? nil : settings
        return plist
    }

    static func ttl(of category: String, in plist: [String: Any]) -> Int? {
        ((plist[category] as? [String: Any])?["TTL"] as? [String: Any])?["Default"] as? Int
    }

    private static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
