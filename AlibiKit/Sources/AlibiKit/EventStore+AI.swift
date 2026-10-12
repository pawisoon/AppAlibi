import Foundation

public enum AIAccessKind: String, CaseIterable, Sendable {
    /// A tccd check.
    case permission
    /// An authd grant.
    case admin
}

/// What one AI client did in one hour: permission checks or admin grants with
/// the same details, folded together.
public struct AIAccessRow: Identifiable, Hashable, Sendable {
    public let hour: Date
    public let client: String
    public let kind: AIAccessKind
    /// The TCC service, or the admin right.
    public let detail: String
    /// The app tccd blamed, or the path that created the authorization.
    public let app: String
    /// The process that accessed, or the path that asked authd.
    public let accessor: String
    public let binaryPath: String
    public let authValue: Int
    public let preflight: Bool
    /// Copied from the daily tables kept before AI clients were tracked. The
    /// hour is the first time seen that day, and the count is for the whole day.
    public let approximate: Bool
    public let count: Int
    public let firstSeen: Date
    public let lastSeen: Date

    public var id: String {
        "\(hour.timeIntervalSince1970)|\(client)|\(kind.rawValue)|\(detail)|\(app)|\(accessor)|\(authValue)|\(preflight)|\(approximate)"
    }

    public var isAllowed: Bool { authValue == 2 || authValue == 3 }
}

public struct AIAccessQuery: Sendable {
    /// Only these client IDs. nil means every client.
    public var clients: Set<String>?
    public var kinds: Set<AIAccessKind>?
    public var includePreflight: Bool
    public var since: Date?
    public var until: Date?
    public var limit: Int

    public init(clients: Set<String>? = nil, kinds: Set<AIAccessKind>? = nil, includePreflight: Bool = true,
                since: Date? = nil, until: Date? = nil, limit: Int = 5_000) {
        self.clients = clients
        self.kinds = kinds
        self.includePreflight = includePreflight
        self.since = since
        self.until = until
        self.limit = limit
    }
}

/// The last result tccd gave an app (or AI client) for a service.
public struct ObservedGrant: Hashable, Sendable {
    public let service: String
    public let authValue: Int
    public let firstAllowed: Date?
    public let lastSeen: Date

    public var isAllowed: Bool { authValue == 2 || authValue == 3 }
}

extension EventStore {
    public static let fullDiskAccessService = "kTCCServiceSystemPolicyAllFiles"

    /// The services that let an app see or drive the Mac, for the observed
    /// inventory and the AI alerts.
    public static let controlServices: [String] = [
        "kTCCServiceAccessibility", "kTCCServicePostEvent", "kTCCServiceListenEvent",
        "kTCCServiceScreenCapture", fullDiskAccessService, "kTCCServiceAppleEvents",
    ]

    static let upsertAIAccessSQL = """
        INSERT INTO ai_access (hour, client, kind, detail, app, accessor, binary_path, auth_value, preflight,
                               approximate, count, first_seen, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (hour, client, kind, detail, app, accessor, auth_value, preflight, approximate) DO UPDATE SET
            count = count + excluded.count,
            binary_path = excluded.binary_path,
            first_seen = min(first_seen, excluded.first_seen),
            last_seen = max(last_seen, excluded.last_seen)
        """

    static func aiAccessValues(hour: Date, client: String, kind: AIAccessKind, detail: String, app: String,
                               accessor: String, binaryPath: String, authValue: Int, preflight: Bool,
                               approximate: Bool, count: Int, firstSeen: Date, lastSeen: Date) -> [SQLiteStatement.Value] {
        [.double(hour.timeIntervalSince1970), .text(client), .text(kind.rawValue), .text(detail), .text(app),
         .text(accessor), .text(binaryPath), .int(Int64(authValue)), .int(preflight ? 1 : 0),
         .int(approximate ? 1 : 0), .int(Int64(count)),
         .double(firstSeen.timeIntervalSince1970), .double(lastSeen.timeIntervalSince1970)]
    }

    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    private static let aiClientMetaPrefix = "ai_client:"

    // MARK: Writing

    /// Sets the clients to track. A client seen for the first time gets the
    /// history the daily tables already hold, marked approximate. A client no
    /// longer in the catalog loses its rows.
    ///
    /// Copying and switching happen under the write lock, so no batch is counted twice.
    public func setAIClients(_ catalog: AIClientCatalog) throws {
        try locked {
            try database.transaction {
                let known = Set(try database.prepare("SELECT key FROM meta WHERE key LIKE 'ai_client:%'")
                    .query { String($0.text(0).dropFirst(Self.aiClientMetaPrefix.count)) })
                let wanted = Set(catalog.clients.map(\.id))
                for removed in known.subtracting(wanted) {
                    try database.prepare("DELETE FROM ai_access WHERE client = ?").run([.text(removed)])
                    try database.prepare("DELETE FROM meta WHERE key = ?").run([.text(Self.aiClientMetaPrefix + removed)])
                }
                let added = wanted.subtracting(known)
                if !added.isEmpty { try copyHistory(for: added, catalog: catalog) }
                for id in added {
                    try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')")
                        .run([.text(Self.aiClientMetaPrefix + id)])
                }
            }
            aiCatalog = catalog
        }
    }

    /// Runs inside the write lock and a transaction.
    private func copyHistory(for clients: Set<String>, catalog: AIClientCatalog) throws {
        let insert = try database.prepare(Self.upsertAIAccessSQL)
        let tccRows = try database.prepare("""
            SELECT service, app, accessor, binary_path, auth_value, preflight, count, first_seen, last_seen FROM tcc_access
            """).query { row in
            (service: row.text(0), app: row.text(1), accessor: row.text(2), binaryPath: row.text(3),
             authValue: Int(row.int(4)), preflight: row.int(5) != 0, count: Int(row.int(6)),
             firstSeen: Date(timeIntervalSince1970: row.double(7)), lastSeen: Date(timeIntervalSince1970: row.double(8)))
        }
        for row in tccRows {
            guard let client = catalog.client(app: row.app, accessor: row.accessor, binaryPath: row.binaryPath),
                  clients.contains(client.id) else { continue }
            try insert.run(Self.aiAccessValues(
                hour: Self.hourStart(row.firstSeen), client: client.id, kind: .permission, detail: row.service,
                app: row.app, accessor: row.accessor, binaryPath: row.binaryPath, authValue: row.authValue,
                preflight: row.preflight, approximate: true, count: row.count, firstSeen: row.firstSeen, lastSeen: row.lastSeen))
        }
        let adminRows = try database.prepare("""
            SELECT right_name, app, client, count, first_seen, last_seen FROM admin_rights
            """).query { row in
            (right: row.text(0), app: row.text(1), client: row.text(2), count: Int(row.int(3)),
             firstSeen: Date(timeIntervalSince1970: row.double(4)), lastSeen: Date(timeIntervalSince1970: row.double(5)))
        }
        for row in adminRows {
            let event = AdminRightEvent(date: row.firstSeen, right: row.right, client: row.client, creator: row.app)
            guard let client = catalog.client(for: event), clients.contains(client.id) else { continue }
            try insert.run(Self.aiAccessValues(
                hour: Self.hourStart(row.firstSeen), client: client.id, kind: .admin, detail: row.right,
                app: row.app, accessor: row.client, binaryPath: row.app, authValue: 2, preflight: false,
                approximate: true, count: row.count, firstSeen: row.firstSeen, lastSeen: row.lastSeen))
        }
    }

    /// The clients `setAIClients` last set.
    public var aiClients: AIClientCatalog {
        locked { aiCatalog }
    }

    // MARK: Reading

    public func aiAccess(_ query: AIAccessQuery = AIAccessQuery()) throws -> [AIAccessRow] {
        var clauses: [String] = []
        var values: [SQLiteStatement.Value] = []
        if let clients = query.clients {
            if clients.isEmpty { return [] }
            clauses.append(Self.inClause("client", count: clients.count))
            values += clients.sorted().map { .text($0) }
        }
        if let kinds = query.kinds {
            if kinds.isEmpty { return [] }
            clauses.append(Self.inClause("kind", count: kinds.count))
            values += kinds.map(\.rawValue).sorted().map { .text($0) }
        }
        if !query.includePreflight { clauses.append("preflight = 0") }
        if let since = query.since {
            clauses.append("last_seen >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        if let until = query.until {
            clauses.append("first_seen < ?")
            values.append(.double(until.timeIntervalSince1970))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.int(Int64(query.limit)))

        return try reading { database in
            try database.prepare("""
                SELECT hour, client, kind, detail, app, accessor, binary_path, auth_value, preflight, approximate,
                       count, first_seen, last_seen
                FROM ai_access \(whereClause) ORDER BY last_seen DESC LIMIT ?
                """).query(values) { row in
                AIAccessRow(
                    hour: Date(timeIntervalSince1970: row.double(0)), client: row.text(1),
                    kind: AIAccessKind(rawValue: row.text(2)) ?? .permission, detail: row.text(3),
                    app: row.text(4), accessor: row.text(5), binaryPath: row.text(6),
                    authValue: Int(row.int(7)), preflight: row.int(8) != 0, approximate: row.int(9) != 0,
                    count: Int(row.int(10)),
                    firstSeen: Date(timeIntervalSince1970: row.double(11)),
                    lastSeen: Date(timeIntervalSince1970: row.double(12))
                )
            }
        }
    }

    /// When each client was first allowed each service, over all history.
    public func aiFirstAllowed() throws -> [String: [String: Date]] {
        try reading { database in
            let rows = try database.prepare("""
                SELECT client, detail, MIN(first_seen) FROM ai_access
                WHERE kind = 'permission' AND auth_value IN (2, 3) GROUP BY client, detail
                """).query { (client: $0.text(0), detail: $0.text(1), date: Date(timeIntervalSince1970: $0.double(2))) }
            var result: [String: [String: Date]] = [:]
            for row in rows { result[row.client, default: [:]][row.detail] = row.date }
            return result
        }
    }

    /// How many allowed checks the client has for the service, on any day.
    public func aiAllowedCount(client: String, service: String) throws -> Int {
        try reading { database in
            try database.prepare("""
                SELECT COALESCE(SUM(count), 0) FROM ai_access
                WHERE client = ? AND kind = 'permission' AND detail = ? AND auth_value IN (2, 3)
                """).query([.text(client), .text(service)]) { Int($0.int(0)) }.first ?? 0
        }
    }

    /// Per client, the last result seen for each control service, over all history.
    public func aiObservedGrants() throws -> [String: [ObservedGrant]] {
        let services = Self.controlServices
        return try reading { database in
            let rows = try database.prepare("""
                SELECT client, detail, auth_value, last_seen,
                       (SELECT MIN(first_seen) FROM ai_access b
                        WHERE b.client = a.client AND b.detail = a.detail AND b.kind = 'permission' AND b.auth_value IN (2, 3))
                FROM ai_access a
                WHERE kind = 'permission' AND \(Self.inClause("detail", count: services.count))
                  AND last_seen = (SELECT MAX(last_seen) FROM ai_access c
                                   WHERE c.client = a.client AND c.detail = a.detail AND c.kind = 'permission')
                """).query(services.map { .text($0) }) { row in
                (client: row.text(0), grant: ObservedGrant(
                    service: row.text(1), authValue: Int(row.int(2)),
                    firstAllowed: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4)),
                    lastSeen: Date(timeIntervalSince1970: row.double(3))))
            }
            var result: [String: [ObservedGrant]] = [:]
            for row in rows where !(result[row.client]?.contains { $0.service == row.grant.service } ?? false) {
                result[row.client, default: []].append(row.grant)
            }
            return result
        }
    }

    /// Clients with admin grants, with the last one.
    public func aiAdminClients() throws -> [String: Date] {
        try reading { database in
            let rows = try database.prepare("SELECT client, MAX(last_seen) FROM ai_access WHERE kind = 'admin' GROUP BY client")
                .query { ($0.text(0), Date(timeIntervalSince1970: $0.double(1))) }
            return Dictionary(rows, uniquingKeysWith: max)
        }
    }

    // MARK: Observed grants

    /// Allowed checks, preflight included, by the app for the service, on any day.
    public func tccAllowedCount(app: String, service: String) throws -> Int {
        try reading { database in
            try database.prepare("""
                SELECT COALESCE(SUM(count), 0) FROM tcc_access WHERE app = ? AND service = ? AND auth_value IN (2, 3)
                """).query([.text(app), .text(service)]) { Int($0.int(0)) }.first ?? 0
        }
    }

    /// Per app, the last result seen for each control service, over all history.
    public func observedGrants(services: [String] = EventStore.controlServices) throws -> [String: [ObservedGrant]] {
        try reading { database in
            let rows = try database.prepare("""
                SELECT app, service, auth_value, MAX(last_seen),
                       (SELECT MIN(first_seen) FROM tcc_access b
                        WHERE b.app = a.app AND b.service = a.service AND b.auth_value IN (2, 3))
                FROM tcc_access a WHERE \(Self.inClause("service", count: services.count))
                GROUP BY app, service
                """).query(services.map { .text($0) }) { row in
                (app: row.text(0), grant: ObservedGrant(
                    service: row.text(1), authValue: Int(row.int(2)),
                    firstAllowed: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4)),
                    lastSeen: Date(timeIntervalSince1970: row.double(3))))
            }
            return Dictionary(grouping: rows, by: \.app).mapValues { $0.map(\.grant) }
        }
    }
}
