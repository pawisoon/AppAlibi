import Foundation

/// Everything one app did: sensor sessions, permission checks and admin
/// rights, for the per-app activity window.
public struct AppActivityQuery: Sendable, Hashable {
    /// The identifier sessions and permission checks are logged under (a bundle ID, usually).
    public var identifier: String
    /// Paths of the app's bundle or binary. authd logs paths, not bundle IDs, so
    /// admin rights match a path itself or anything inside it.
    public var paths: [String]
    public var since: Date?
    public var includePreflight: Bool
    /// Per source. The timeline is newest first, so the limit drops the oldest.
    public var limit: Int

    public init(identifier: String, paths: [String] = [], since: Date? = nil,
                includePreflight: Bool = false, limit: Int = 2_000) {
        self.identifier = identifier
        self.paths = paths
        self.since = since
        self.includePreflight = includePreflight
        self.limit = limit
    }
}

/// One line of an app's timeline.
public enum AppTimelineEvent: Identifiable, Hashable, Sendable {
    case sensor(SensorSession)
    /// One day's checks for one permission with one result.
    case permission(TCCAggregate)
    /// One day's grants of one right.
    case admin(AdminRightAggregate)

    public var id: String {
        switch self {
        case .sensor(let session): "s|\(session.id)"
        case .permission(let row): "p|\(row.id)"
        case .admin(let row): "a|\(row.id)"
        }
    }

    /// When it started, or for a day's aggregate, when it was first seen.
    public var start: Date {
        switch self {
        case .sensor(let session): session.startedAt
        case .permission(let row): row.firstSeen
        case .admin(let row): row.firstSeen
        }
    }

    /// The timeline sorts by this: the latest moment the line covers.
    public func end(now: Date = Date()) -> Date {
        switch self {
        case .sensor(let session): session.endedAt ?? max(now, session.startedAt)
        case .permission(let row): row.lastSeen
        case .admin(let row): row.lastSeen
        }
    }
}

/// One protected folder or volume an app reached for, over the whole range.
public struct AppFolderAccess: Identifiable, Hashable, Sendable {
    public let service: String
    /// Real checks, preflight left out.
    public let count: Int
    public let allowed: Int
    public let denied: Int
    public let firstSeen: Date
    public let lastSeen: Date
    /// The result of the latest check.
    public let lastResult: Int

    public var id: String { service }
    public var serviceName: String { TCCService.displayName(for: service) }
}

public struct AppActivity: Sendable {
    public let timeline: [AppTimelineEvent]
    public let folders: [AppFolderAccess]
    /// Sensor time inside the range, longest first.
    public let sensorTime: [(sensor: Sensor, duration: TimeInterval)]
    public let permissionChecks: Int
    public let deniedChecks: Int
    public let adminGrants: Int

    public var isEmpty: Bool { timeline.isEmpty }

    public static let empty = AppActivity(timeline: [], folders: [], sensorTime: [],
                                          permissionChecks: 0, deniedChecks: 0, adminGrants: 0)
}

/// Where a file permission points on disk, so the window can open it in Finder.
public enum ProtectedFolder {
    /// nil for permissions that are not about one folder.
    public static func url(for service: String,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let short = service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
        switch short {
        case "SystemPolicyDesktopFolder": return home.appendingPathComponent("Desktop", isDirectory: true)
        case "SystemPolicyDocumentsFolder": return home.appendingPathComponent("Documents", isDirectory: true)
        case "SystemPolicyDownloadsFolder": return home.appendingPathComponent("Downloads", isDirectory: true)
        case "SystemPolicyRemovableVolumes", "SystemPolicyNetworkVolumes": return URL(fileURLWithPath: "/Volumes", isDirectory: true)
        case "SystemPolicyAllFiles": return URL(fileURLWithPath: "/", isDirectory: true)
        case "SystemPolicyAppBundles": return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case "SystemPolicyAppData", "SystemPolicyAppDataDetailed":
            return home.appendingPathComponent("Library/Containers", isDirectory: true)
        case "Ubiquity": return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        default: return nil
        }
    }

    /// Permissions that guard files and folders, including iCloud Drive.
    public static func isFolder(_ service: String) -> Bool {
        TCCService.isFileAccess(service) || service == "kTCCServiceUbiquity"
    }
}

extension EventStore {
    public func appActivity(_ query: AppActivityQuery, now: Date = Date()) throws -> AppActivity {
        let sessions = try sessions(SessionQuery(apps: [query.identifier], since: query.since, limit: query.limit))
        let checks = try tccAggregates(TCCQuery(apps: [query.identifier], includePreflight: query.includePreflight,
                                                includeApple: true, since: query.since, limit: query.limit))
        let rights = try adminRights(paths: query.paths, since: query.since, limit: query.limit)

        var timeline = sessions.map(AppTimelineEvent.sensor)
            + checks.map(AppTimelineEvent.permission)
            + rights.map(AppTimelineEvent.admin)
        timeline.sort { $0.end(now: now) > $1.end(now: now) }

        var sensorTime: [Sensor: TimeInterval] = [:]
        for session in sessions {
            let start = max(session.startedAt, query.since ?? session.startedAt)
            let end = session.endedAt ?? max(now, session.startedAt)
            sensorTime[session.sensor, default: 0] += max(0, end.timeIntervalSince(start))
        }

        let real = checks.filter { !$0.preflight }
        return AppActivity(
            timeline: timeline,
            folders: Self.folders(from: real),
            sensorTime: sensorTime.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) },
            permissionChecks: real.reduce(0) { $0 + $1.count },
            deniedChecks: real.filter { $0.authValue == 0 }.reduce(0) { $0 + $1.count },
            adminGrants: rights.reduce(0) { $0 + $1.count }
        )
    }

    /// Admin rights created by one of the paths, or by anything inside one.
    func adminRights(paths: [String], since: Date?, limit: Int) throws -> [AdminRightAggregate] {
        let paths = paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        var clauses: [String] = []
        var values: [SQLiteStatement.Value] = []
        for path in paths {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            clauses.append("app = ? OR substr(app, 1, ?) = ?")
            values += [.text(path), .int(Int64(prefix.utf8.count)), .text(prefix)]
        }
        var whereClause = "WHERE (" + clauses.joined(separator: " OR ") + ")"
        if let since {
            whereClause += " AND last_seen >= ?"
            values.append(.double(since.timeIntervalSince1970))
        }
        values.append(.int(Int64(limit)))
        return try reading { database in
            try database.prepare("""
                SELECT day, right_name, app, client, count, first_seen, last_seen
                FROM admin_rights \(whereClause) ORDER BY last_seen DESC LIMIT ?
                """).query(values) { row in
                AdminRightAggregate(
                    day: row.text(0), right: row.text(1), app: row.text(2), client: row.text(3),
                    count: Int(row.int(4)),
                    firstSeen: Date(timeIntervalSince1970: row.double(5)),
                    lastSeen: Date(timeIntervalSince1970: row.double(6))
                )
            }
        }
    }

    /// Folds the days and results of each folder permission together, most recent first.
    static func folders(from rows: [TCCAggregate]) -> [AppFolderAccess] {
        let byService = Dictionary(grouping: rows.filter { ProtectedFolder.isFolder($0.service) }, by: \.service)
        return byService.map { service, rows in
            let latest = rows.max { $0.lastSeen < $1.lastSeen }!
            return AppFolderAccess(
                service: service,
                count: rows.reduce(0) { $0 + $1.count },
                allowed: rows.filter { $0.authValue == 2 || $0.authValue == 3 }.reduce(0) { $0 + $1.count },
                denied: rows.filter { $0.authValue == 0 }.reduce(0) { $0 + $1.count },
                firstSeen: rows.map(\.firstSeen).min()!,
                lastSeen: latest.lastSeen,
                lastResult: latest.authValue
            )
        }
        .sorted { ($0.lastSeen, $0.service) > ($1.lastSeen, $1.service) }
    }
}
