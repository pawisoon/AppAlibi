import Foundation

public struct SensorSession: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let sensor: Sensor
    public let app: String
    public let startedAt: Date
    public let endedAt: Date?

    public var isActive: Bool { endedAt == nil }

    public func duration(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }
}

public struct TCCAggregate: Identifiable, Hashable, Sendable {
    public let day: String
    public let service: String
    public let app: String
    public let accessor: String
    public let binaryPath: String
    public let authValue: Int
    public let preflight: Bool
    public let count: Int
    public let firstSeen: Date
    public let lastSeen: Date

    public var id: String { "\(day)|\(service)|\(app)|\(accessor)|\(authValue)|\(preflight)" }
    public var serviceName: String { TCCService.displayName(for: service) }
    public var resultName: String { TCCService.resultName(for: authValue) }
}

/// One right granted to one app on one day.
public struct AdminRightAggregate: Identifiable, Hashable, Sendable {
    public let day: String
    public let right: String
    /// Path of the process that created the authorization (see `AdminRightEvent.app`).
    public let app: String
    /// Path of the process that asked authd for the right.
    public let client: String
    public let count: Int
    public let firstSeen: Date
    public let lastSeen: Date

    public var id: String { "\(day)|\(right)|\(app)|\(client)" }
    public var rightName: String { AdminRight.displayName(for: right) }
}

public struct AdminRightQuery: Sendable {
    /// Only these app paths. nil means any app.
    public var apps: Set<String>?
    public var appContains: String?
    public var since: Date?
    public var limit: Int

    public init(apps: Set<String>? = nil, appContains: String? = nil, since: Date? = nil, limit: Int = 1_000) {
        self.apps = apps
        self.appContains = appContains
        self.since = since
        self.limit = limit
    }
}

public struct SessionQuery: Sendable {
    public var sensors: Set<Sensor>?
    /// Only these app identifiers. nil means any app.
    public var apps: Set<String>?
    public var appContains: String?
    public var since: Date?
    public var onlyActive: Bool
    public var limit: Int

    public init(sensors: Set<Sensor>? = nil, apps: Set<String>? = nil, appContains: String? = nil,
                since: Date? = nil, onlyActive: Bool = false, limit: Int = 500) {
        self.sensors = sensors
        self.apps = apps
        self.onlyActive = onlyActive
        self.appContains = appContains
        self.since = since
        self.limit = limit
    }
}

public struct TCCQuery: Sendable {
    /// Only these app identifiers. nil means any app (subject to `includeApple`).
    public var apps: Set<String>?
    public var includePreflight: Bool
    public var includeApple: Bool
    public var fileAccessOnly: Bool
    public var appContains: String?
    public var since: Date?
    public var limit: Int

    public init(apps: Set<String>? = nil, includePreflight: Bool = false, includeApple: Bool = false,
                fileAccessOnly: Bool = false, appContains: String? = nil, since: Date? = nil, limit: Int = 1_000) {
        self.apps = apps
        self.includePreflight = includePreflight
        self.includeApple = includeApple
        self.fileAccessOnly = fileAccessOnly
        self.appContains = appContains
        self.since = since
        self.limit = limit
    }
}

/// SQLite-backed history. All methods are thread-safe.
///
/// Two connections: the collector writes through one, the history views read
/// through the other. In WAL mode a reader does not wait for a write
/// transaction, so a view never stalls behind a big catch-up batch.
public final class EventStore: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let lock = NSLock()
    private let reader: SQLiteDatabase
    private let readLock = NSLock()
    public let path: String
    /// Control Center briefly drops and re-adds a sensor during calls. A restart
    /// within this many seconds continues the previous session instead of opening a new one.
    public let mergeGap: TimeInterval

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AppAlibi", isDirectory: true).appendingPathComponent("alibi.sqlite")
    }

    public init(url: URL = EventStore.defaultURL, mergeGap: TimeInterval = 5) throws {
        self.mergeGap = mergeGap
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        path = url.path
        database = try SQLiteDatabase(path: url.path)
        reader = try SQLiteDatabase(path: url.path, queryOnly: true)
        try migrate()
    }

    private func migrate() throws {
        try database.execute("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY,
            sensor TEXT NOT NULL,
            app TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL
        );
        CREATE INDEX IF NOT EXISTS sessions_started ON sessions(started_at DESC);
        CREATE INDEX IF NOT EXISTS sessions_open ON sessions(sensor, app) WHERE ended_at IS NULL;
        CREATE TABLE IF NOT EXISTS tcc_access (
            day TEXT NOT NULL,
            service TEXT NOT NULL,
            app TEXT NOT NULL,
            accessor TEXT NOT NULL,
            binary_path TEXT NOT NULL,
            auth_value INTEGER NOT NULL,
            preflight INTEGER NOT NULL,
            count INTEGER NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            PRIMARY KEY (day, service, app, accessor, auth_value, preflight)
        );
        CREATE INDEX IF NOT EXISTS tcc_last_seen ON tcc_access(last_seen DESC);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS screen_locks (
            id INTEGER PRIMARY KEY,
            locked_at REAL NOT NULL,
            unlocked_at REAL
        );
        CREATE INDEX IF NOT EXISTS screen_locks_locked ON screen_locks(locked_at DESC);
        CREATE TABLE IF NOT EXISTS admin_rights (
            day TEXT NOT NULL,
            right_name TEXT NOT NULL,
            app TEXT NOT NULL,
            client TEXT NOT NULL,
            count INTEGER NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            PRIMARY KEY (day, right_name, app, client)
        );
        CREATE INDEX IF NOT EXISTS admin_rights_last_seen ON admin_rights(last_seen DESC);
        """)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Queries for the UI and alerts. They see every committed batch.
    private func reading<T>(_ body: (SQLiteDatabase) throws -> T) rethrows -> T {
        readLock.lock()
        defer { readLock.unlock() }
        return try body(reader)
    }

    // MARK: Writing

    /// Writes a batch of events and the new checkpoint in one transaction.
    public func record(_ events: [CollectedEvent], lastProcessed: Date?) throws {
        try locked {
            try database.transaction {
                let insertSession = try database.prepare(
                    "INSERT INTO sessions (sensor, app, started_at) VALUES (?, ?, ?)")
                let resumeSession = try database.prepare("""
                    UPDATE sessions SET ended_at = NULL WHERE id = (
                        SELECT id FROM sessions
                        WHERE sensor = ? AND app = ? AND ended_at IS NOT NULL AND ended_at >= ?
                        ORDER BY ended_at DESC LIMIT 1)
                    """)
                let endSession = try database.prepare(
                    "UPDATE sessions SET ended_at = ? WHERE sensor = ? AND app = ? AND ended_at IS NULL")
                let upsertTCC = try database.prepare("""
                    INSERT INTO tcc_access (day, service, app, accessor, binary_path, auth_value, preflight, count, first_seen, last_seen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT (day, service, app, accessor, auth_value, preflight) DO UPDATE SET
                        count = count + 1,
                        binary_path = excluded.binary_path,
                        first_seen = min(first_seen, excluded.first_seen),
                        last_seen = max(last_seen, excluded.last_seen)
                    """)
                let lockScreen = try database.prepare("""
                    INSERT INTO screen_locks (locked_at)
                    SELECT ? WHERE NOT EXISTS (SELECT 1 FROM screen_locks WHERE unlocked_at IS NULL)
                    """)
                let upsertAdminRight = try database.prepare("""
                    INSERT INTO admin_rights (day, right_name, app, client, count, first_seen, last_seen)
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT (day, right_name, app, client) DO UPDATE SET
                        count = count + 1,
                        first_seen = min(first_seen, excluded.first_seen),
                        last_seen = max(last_seen, excluded.last_seen)
                    """)
                // An unlock with no lock before it (the first import started mid-lock) is dropped.
                let unlockScreen = try database.prepare(
                    "UPDATE screen_locks SET unlocked_at = ? WHERE unlocked_at IS NULL")

                for event in events {
                    switch event {
                    case .sensor(let sensorEvent):
                        let a = sensorEvent.attribution
                        let time = sensorEvent.date.timeIntervalSince1970
                        switch sensorEvent.kind {
                        case .started:
                            try resumeSession.run([.text(a.sensor.rawValue), .text(a.app), .double(time - mergeGap)])
                            if database.changes == 0 {
                                try insertSession.run([.text(a.sensor.rawValue), .text(a.app), .double(time)])
                            }
                        case .ended:
                            try endSession.run([.double(time), .text(a.sensor.rawValue), .text(a.app)])
                        }
                    case .tcc(let tcc):
                        let time = tcc.date.timeIntervalSince1970
                        try upsertTCC.run([
                            .text(Self.dayFormatter.string(from: tcc.date)),
                            .text(tcc.service), .text(tcc.app), .text(tcc.accessor), .text(tcc.binaryPath),
                            .int(Int64(tcc.authValue)), .int(tcc.preflight ? 1 : 0),
                            .double(time), .double(time),
                        ])
                    case .screenLock(let lock):
                        let time = lock.date.timeIntervalSince1970
                        try (lock.locked ? lockScreen : unlockScreen).run([.double(time)])
                    case .adminRight(let right):
                        let time = right.date.timeIntervalSince1970
                        try upsertAdminRight.run([
                            .text(Self.dayFormatter.string(from: right.date)),
                            .text(right.right), .text(right.app), .text(right.client),
                            .double(time), .double(time),
                        ])
                    }
                }

                if let lastProcessed {
                    try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_processed', ?)")
                        .run([.text(String(lastProcessed.timeIntervalSince1970))])
                }
            }
        }
    }

    /// Deletes all history. Keeps the checkpoint, so the collector does not
    /// re-import the deleted past from the unified log on its next restart.
    public func deleteAll() throws {
        try locked {
            try database.execute("DELETE FROM sessions; DELETE FROM tcc_access; DELETE FROM screen_locks; DELETE FROM admin_rights; VACUUM;")
        }
    }

    /// Deletes history from before the cutoff, for the retention setting. A
    /// session or lock counts by its end, so one that runs across the cutoff, or
    /// is still open, stays whole. Permission and admin rows go by day. Keeps the checkpoint.
    /// Returns the number of rows deleted.
    @discardableResult
    public func deleteOlderThan(_ cutoff: Date) throws -> Int {
        let time = cutoff.timeIntervalSince1970
        return try locked {
            try database.transaction {
                var deleted = 0
                try database.prepare("DELETE FROM sessions WHERE ended_at IS NOT NULL AND ended_at < ?").run([.double(time)])
                deleted += Int(database.changes)
                let day = Self.dayFormatter.string(from: cutoff)
                try database.prepare("DELETE FROM tcc_access WHERE day < ?").run([.text(day)])
                deleted += Int(database.changes)
                try database.prepare("DELETE FROM admin_rights WHERE day < ?").run([.text(day)])
                deleted += Int(database.changes)
                try database.prepare("DELETE FROM screen_locks WHERE unlocked_at IS NOT NULL AND unlocked_at < ?").run([.double(time)])
                deleted += Int(database.changes)
                return deleted
            }
        }
    }

    /// The Mac shut down or restarted while locked, so loginwindow never logged
    /// the unlock. Ends a lock still open from before `bootTime` at that time,
    /// so the session after the restart does not count as locked.
    public func endScreenLock(openBefore bootTime: Date) throws {
        try locked {
            try database.prepare("UPDATE screen_locks SET unlocked_at = ? WHERE unlocked_at IS NULL AND locked_at < ?")
                .run([.double(bootTime.timeIntervalSince1970), .double(bootTime.timeIntervalSince1970)])
        }
    }

    // MARK: Reading

    public func lastProcessed() throws -> Date? {
        try locked {
            let values = try database.prepare("SELECT value FROM meta WHERE key = 'last_processed'")
                .query { $0.text(0) }
            return values.first.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Sources added after the first release. Databases from before one have a
    /// checkpoint past its lines still in the log, so they get one import of
    /// those (`Collector`). New databases read every source in the catch-up.
    public enum HistorySource: String, CaseIterable, Sendable {
        case screenLocks = "screen_locks_imported"
        case adminRights = "admin_rights_imported"

        public var predicate: String {
            switch self {
            case .screenLocks: LogPredicates.screenLock
            case .adminRights: LogPredicates.adminRights
            }
        }
    }

    public func needsHistoryImport(_ source: HistorySource) throws -> Bool {
        try locked {
            try database.prepare("SELECT 1 FROM meta WHERE key = ?").query([.text(source.rawValue)]) { _ in true }.isEmpty
        }
    }

    public func markHistoryImported(_ source: HistorySource) throws {
        try locked {
            try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')").run([.text(source.rawValue)])
        }
    }

    /// A lock with no unlock yet.
    public func isScreenLocked() throws -> Bool {
        try locked {
            try database.prepare("SELECT 1 FROM screen_locks WHERE unlocked_at IS NULL LIMIT 1").query { _ in true }.isEmpty == false
        }
    }

    /// Locks that overlap the interval, or all of them. An open lock runs to `now`.
    public func screenLocks(overlapping interval: DateInterval? = nil, now: Date = Date()) throws -> ScreenLockSpans {
        var sql = "SELECT locked_at, unlocked_at FROM screen_locks"
        var values: [SQLiteStatement.Value] = []
        if let interval {
            sql += " WHERE locked_at < ? AND (unlocked_at IS NULL OR unlocked_at > ?)"
            values = [.double(interval.end.timeIntervalSince1970), .double(interval.start.timeIntervalSince1970)]
        }
        let spans = try reading { database in
            try database.prepare(sql + " ORDER BY locked_at").query(values) { row -> DateInterval in
                let start = Date(timeIntervalSince1970: row.double(0))
                let end = row.isNull(1) ? max(now, start) : Date(timeIntervalSince1970: row.double(1))
                return DateInterval(start: start, end: max(end, start))
            }
        }
        return ScreenLockSpans(spans)
    }

    /// The lock that the unlock at `date` ended.
    public func screenLock(endingAt date: Date) throws -> DateInterval? {
        try reading { database in
            try database.prepare("""
                SELECT locked_at, unlocked_at FROM screen_locks WHERE unlocked_at = ? LIMIT 1
                """).query([.double(date.timeIntervalSince1970)]) {
                DateInterval(start: Date(timeIntervalSince1970: $0.double(0)), end: Date(timeIntervalSince1970: $0.double(1)))
            }.first
        }
    }

    public func openAttributions() throws -> Set<Attribution> {
        try locked {
            let rows = try database.prepare("SELECT sensor, app FROM sessions WHERE ended_at IS NULL")
                .query { Attribution(sensor: Sensor(rawValue: $0.text(0)), app: $0.text(1)) }
            return Set(rows)
        }
    }

    public func sessions(_ query: SessionQuery = SessionQuery()) throws -> [SensorSession] {
        var clauses: [String] = []
        var values: [SQLiteStatement.Value] = []
        if let sensors = query.sensors {
            if sensors.isEmpty { return [] }
            clauses.append(Self.inClause("sensor", count: sensors.count))
            values += sensors.sorted().map { .text($0.rawValue) }
        }
        if let apps = query.apps {
            if apps.isEmpty { return [] }
            clauses.append(Self.inClause("app", count: apps.count))
            values += apps.sorted().map { .text($0) }
        }
        if let text = query.appContains, !text.isEmpty {
            clauses.append("app LIKE ?")
            values.append(.text("%\(text)%"))
        }
        if query.onlyActive { clauses.append("ended_at IS NULL") }
        if let since = query.since {
            clauses.append("(started_at >= ? OR ended_at IS NULL OR ended_at >= ?)")
            values += [.double(since.timeIntervalSince1970), .double(since.timeIntervalSince1970)]
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.int(Int64(query.limit)))

        return try reading { database in
            try database.prepare("""
                SELECT id, sensor, app, started_at, ended_at FROM sessions
                \(whereClause) ORDER BY started_at DESC LIMIT ?
                """).query(values) { row in
                SensorSession(
                    id: row.int(0),
                    sensor: Sensor(rawValue: row.text(1)),
                    app: row.text(2),
                    startedAt: Date(timeIntervalSince1970: row.double(3)),
                    endedAt: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4))
                )
            }
        }
    }

    /// Every app identifier that has sensor sessions.
    public func sessionApps() throws -> [String] {
        try reading { database in
            try database.prepare("SELECT DISTINCT app FROM sessions").query { $0.text(0) }
        }
    }

    /// Every app identifier with permission checks, with the binary paths logged for it.
    public func tccApps() throws -> [(app: String, binaryPath: String)] {
        try reading { database in
            try database.prepare("SELECT DISTINCT app, binary_path FROM tcc_access").query { ($0.text(0), $0.text(1)) }
        }
    }

    /// How many times the app made a real (not preflight) check for the service, on any day.
    public func tccAccessCount(app: String, service: String) throws -> Int {
        try reading { database in
            let counts = try database.prepare("""
                SELECT COALESCE(SUM(count), 0) FROM tcc_access WHERE app = ? AND service = ? AND preflight = 0
                """).query([.text(app), .text(service)]) { Int($0.int(0)) }
            return counts.first ?? 0
        }
    }

    /// Every app path with granted admin rights.
    public func adminRightApps() throws -> [String] {
        try reading { database in
            try database.prepare("SELECT DISTINCT app FROM admin_rights").query { $0.text(0) }
        }
    }

    public func adminRights(_ query: AdminRightQuery = AdminRightQuery()) throws -> [AdminRightAggregate] {
        var clauses: [String] = []
        var values: [SQLiteStatement.Value] = []
        if let apps = query.apps {
            if apps.isEmpty { return [] }
            clauses.append(Self.inClause("app", count: apps.count))
            values += apps.sorted().map { .text($0) }
        }
        if let text = query.appContains, !text.isEmpty {
            clauses.append("(app LIKE ? OR client LIKE ? OR right_name LIKE ?)")
            values += Array(repeating: .text("%\(text)%"), count: 3)
        }
        if let since = query.since {
            clauses.append("last_seen >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.int(Int64(query.limit)))

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

    private static func inClause(_ column: String, count: Int) -> String {
        "\(column) IN (\(Array(repeating: "?", count: count).joined(separator: ",")))"
    }

    public func tccAggregates(_ query: TCCQuery = TCCQuery()) throws -> [TCCAggregate] {
        var clauses: [String] = []
        var values: [SQLiteStatement.Value] = []
        if let apps = query.apps {
            if apps.isEmpty { return [] }
            clauses.append(Self.inClause("app", count: apps.count))
            values += apps.sorted().map { .text($0) }
        }
        if !query.includePreflight { clauses.append("preflight = 0") }
        if !query.includeApple { clauses.append("app NOT LIKE 'com.apple.%'") }
        if query.fileAccessOnly { clauses.append("service LIKE 'kTCCServiceSystemPolicy%'") }
        if let text = query.appContains, !text.isEmpty {
            clauses.append("(app LIKE ? OR accessor LIKE ? OR binary_path LIKE ?)")
            values += Array(repeating: .text("%\(text)%"), count: 3)
        }
        if let since = query.since {
            clauses.append("last_seen >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.int(Int64(query.limit)))

        return try reading { database in
            try database.prepare("""
                SELECT day, service, app, accessor, binary_path, auth_value, preflight, count, first_seen, last_seen
                FROM tcc_access \(whereClause) ORDER BY last_seen DESC LIMIT ?
                """).query(values) { row in
                TCCAggregate(
                    day: row.text(0), service: row.text(1), app: row.text(2), accessor: row.text(3),
                    binaryPath: row.text(4), authValue: Int(row.int(5)), preflight: row.int(6) != 0,
                    count: Int(row.int(7)),
                    firstSeen: Date(timeIntervalSince1970: row.double(8)),
                    lastSeen: Date(timeIntervalSince1970: row.double(9))
                )
            }
        }
    }
}
