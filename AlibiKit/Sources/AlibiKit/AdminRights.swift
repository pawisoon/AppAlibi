import Foundation
import Security

/// authd granted an authorization right: an admin password prompt, an installer,
/// a helper that changes system daemons.
public struct AdminRightEvent: Equatable, Sendable {
    public let date: Date
    /// `system.privilege.admin`, `system.install.software` and so on.
    public let right: String
    /// The process that asked authd for the right.
    public let client: String
    /// The process that created the authorization. Usually the client; for
    /// Software Update it is the app that asked the user while a daemon does the work.
    public let creator: String

    public init(date: Date, right: String, client: String, creator: String) {
        self.date = date
        self.right = right
        self.client = client
        self.creator = creator
    }

    /// The app to blame, as a path: the creator, else the client.
    public var app: String { creator.isEmpty ? client : creator }
}

public enum AdminRightParser {
    /// Parses authd's
    /// `Succeeded authorizing right 'system.privilege.admin' by client '/usr/libexec/mdmclient' [1234] for authorization created by '/usr/libexec/mdmclient' [1234] (3,0) (engine 42)`.
    /// Returns nil for other lines and for login rights (`system.login.*`):
    /// loginwindow takes one on every password unlock, which screen lock tracking covers.
    ///
    /// Failed requests are not logged with the right or the client (only
    /// `Fatal: authorization denied ... (engine N)`), so only grants are recorded.
    public static func event(from entry: LogEntry) -> AdminRightEvent? {
        let message = entry.eventMessage
        guard message.hasPrefix(LogPredicates.adminRightPrefix) else { return nil }
        var rest = message.dropFirst(LogPredicates.adminRightPrefix.count)
        guard let rightEnd = rest.firstIndex(of: "'") else { return nil }
        let right = String(rest[..<rightEnd])
        guard !right.isEmpty, !right.hasPrefix("system.login.") else { return nil }
        rest = rest[rightEnd...]

        guard let client = quotedPath(after: "' by client '", in: &rest) else { return nil }
        let creator = quotedPath(after: " for authorization created by '", in: &rest) ?? ""
        return AdminRightEvent(date: entry.timestamp, right: right, client: client, creator: creator)
    }

    /// The path between `marker` and the `' [pid]` that follows it. Paths can hold spaces
    /// (`Software Update.app`), so the end is the quote before the pid, not the next quote.
    private static func quotedPath(after marker: String, in rest: inout Substring) -> String? {
        guard let start = rest.range(of: marker),
              let end = rest.range(of: "' [", range: start.upperBound..<rest.endIndex)
        else { return nil }
        let path = String(rest[start.upperBound..<end.lowerBound])
        rest = rest[end.upperBound...]
        return path.isEmpty ? nil : path
    }
}

public enum AdminRight {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var openRights: [String: Bool] = [:]

    /// Whether the right's rule is `allow`: authd grants it to any process
    /// without asking (`system.burn`, `system.hdd.smart`). Those are not admin
    /// rights, and an alert for one would cry wolf. Reads the rule from the
    /// authorization database, which needs no root; a right it cannot read counts as real.
    public static func isOpenToEveryone(_ right: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = openRights[right] { return cached }
        var info: CFDictionary?
        let open = AuthorizationRightGet(right, &info) == errAuthorizationSuccess
            && (info as? [String: Any])?["class"] as? String == "allow"
        openRights[right] = open
        return open
    }

    /// `system.install.apple-software` -> "Install Apple software". Unknown rights keep their name.
    public static func displayName(for right: String) -> String {
        switch right {
        case "system.privilege.admin":
            return String(localized: "Administrator access", bundle: .module)
        case "system.privilege.taskport", "system.privilege.taskport.debug":
            return String(localized: "Debug other apps", bundle: .module)
        case "com.apple.ServiceManagement.daemons.modify":
            return String(localized: "Change background services", bundle: .module)
        case "com.apple.ServiceManagement.blesshelper":
            return String(localized: "Install privileged helper", bundle: .module)
        case "com.apple.SoftwareUpdate.modify-settings":
            return String(localized: "Change Software Update settings", bundle: .module)
        // Variants get their own names, or one grant reads as two identical rows.
        case "system.install.apple-software.standard-user":
            return String(localized: "Install Apple software (standard user)", bundle: .module)
        case "system.install.software.mdm-provided":
            return String(localized: "Install software from MDM", bundle: .module)
        default:
            break
        }
        if right.hasPrefix("system.install.apple-software") {
            return String(localized: "Install Apple software", bundle: .module)
        }
        if right.hasPrefix("system.install.") {
            return String(localized: "Install software", bundle: .module)
        }
        if right.hasPrefix("system.services.systemconfiguration.network") {
            return String(localized: "Change network settings", bundle: .module)
        }
        if right.hasPrefix("system.preferences") {
            return String(localized: "Change system settings", bundle: .module)
        }
        return right
    }
}
