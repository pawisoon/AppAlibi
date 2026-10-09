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
public final class EventStore: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let lock = NSLock()
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
        """)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
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
            try database.execute("DELETE FROM sessions; DELETE FROM tcc_access; VACUUM;")
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

        return try locked {
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
        try locked {
            try database.prepare("SELECT DISTINCT app FROM sessions").query { $0.text(0) }
        }
    }

    /// Every app identifier with permission checks, with the binary paths logged for it.
    public func tccApps() throws -> [(app: String, binaryPath: String)] {
        try locked {
            try database.prepare("SELECT DISTINCT app, binary_path FROM tcc_access").query { ($0.text(0), $0.text(1)) }
        }
    }

    /// How many times the app made a real (not preflight) check for the service, on any day.
    public func tccAccessCount(app: String, service: String) throws -> Int {
        try locked {
            let counts = try database.prepare("""
                SELECT COALESCE(SUM(count), 0) FROM tcc_access WHERE app = ? AND service = ? AND preflight = 0
                """).query([.text(app), .text(service)]) { Int($0.int(0)) }
            return counts.first ?? 0
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

        return try locked {
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
