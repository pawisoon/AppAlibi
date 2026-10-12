import Foundation

/// One line of the AI tab: a sensor session, permission checks in one hour, or an admin grant.
public struct AIActivity: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case sensor, permission, admin
    }

    public let id: String
    /// An `AIClient` ID.
    public let client: String
    public let kind: Kind
    /// Session start, or the first check in the row.
    public let start: Date
    /// Session end (nil while active), or the last check in the row.
    public let end: Date?
    /// The sensor raw value, the TCC service or the admin right.
    public let detail: String
    /// The identifier or path the log blamed.
    public let app: String
    /// The process that did it, when it is not the app itself.
    public let accessor: String
    public let binaryPath: String
    /// tccd's answer. nil for sessions; 2 for admin grants.
    public let authValue: Int?
    public let preflight: Bool
    public let count: Int
    /// See `AIAccessRow.approximate`.
    public let approximate: Bool
    /// The client's first allowed use of this service.
    public internal(set) var isFirstTime = false
    /// A screen recording that came with a mouse and keyboard control check.
    public internal(set) var isProbablyComputerUse = false
    /// Whether any of it happened while the screen was locked.
    public internal(set) var whileLocked = false

    /// When it happened, for sorting and the Time column: a session's start, a row's last check.
    public var time: Date { kind == .sensor ? start : (end ?? start) }

    public var sensor: Sensor? { kind == .sensor ? Sensor(rawValue: detail) : nil }

    public var isAllowed: Bool { authValue.map { $0 == 2 || $0 == 3 } ?? true }

    public var isDenied: Bool { authValue == 0 }

    public func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }

    /// In plain words, e.g. "Recorded the screen", "Opened Documents Folder".
    public var what: String {
        switch kind {
        case .sensor:
            switch Sensor(rawValue: detail) {
            case .screen: return String(localized: "Recorded the screen", bundle: .module)
            case .microphone: return String(localized: "Used the microphone", bundle: .module)
            case .camera: return String(localized: "Used the camera", bundle: .module)
            case .location: return String(localized: "Used your location", bundle: .module)
            default: return String(localized: "Used \(Sensor(rawValue: detail).displayName)", bundle: .module)
            }
        case .admin:
            return String(localized: "Got admin rights: \(AdminRight.displayName(for: detail))", bundle: .module)
        case .permission:
            let short = detail.hasPrefix("kTCCService") ? String(detail.dropFirst("kTCCService".count)) : detail
            let name = TCCService.displayName(for: detail)
            switch short {
            case "SystemPolicyAllFiles":
                return String(localized: "Full Disk Access check", bundle: .module)
            case "Accessibility", "PostEvent":
                return isAllowed ? String(localized: "Can control mouse and keyboard", bundle: .module)
                    : String(localized: "Asked to control the Mac", bundle: .module)
            case "ListenEvent":
                return isAllowed ? String(localized: "Can watch keyboard and mouse", bundle: .module)
                    : String(localized: "Asked to watch keyboard and mouse", bundle: .module)
            case "ScreenCapture":
                return isAllowed ? String(localized: "Can record the screen", bundle: .module)
                    : String(localized: "Asked to record the screen", bundle: .module)
            case "AppleEvents":
                return isAllowed ? String(localized: "Can control other apps", bundle: .module)
                    : String(localized: "Asked to control other apps", bundle: .module)
            default:
                if isDenied { return String(localized: "Denied: \(name)", bundle: .module) }
                if preflight { return String(localized: "Checked access: \(name)", bundle: .module) }
                if TCCService.isFileAccess(detail) { return String(localized: "Opened: \(name)", bundle: .module) }
                return String(localized: "Accessed: \(name)", bundle: .module)
            }
        }
    }

    /// The result for permission rows, nil for the rest.
    public var resultName: String? {
        guard kind == .permission, let authValue else { return nil }
        let name = TCCService.resultName(for: authValue)
        return preflight ? String(localized: "\(name) (check)", bundle: .module) : name
    }
}

public struct AITimelineQuery: Sendable {
    /// Only these client IDs. nil means every client.
    public var clients: Set<String>?
    public var kinds: Set<AIActivity.Kind>?
    /// "Real access only" off: preflight checks too.
    public var includePreflight: Bool
    public var since: Date?
    public var until: Date?
    public var limit: Int

    public init(clients: Set<String>? = nil, kinds: Set<AIActivity.Kind>? = nil, includePreflight: Bool = false,
                since: Date? = nil, until: Date? = nil, limit: Int = 2_000) {
        self.clients = clients
        self.kinds = kinds
        self.includePreflight = includePreflight
        self.since = since
        self.until = until
        self.limit = limit
    }
}

public enum AITimeline {
    static let mouseAndKeyboard: Set<String> = ["kTCCServiceAccessibility", "kTCCServicePostEvent"]
    /// A control check this close to a screen recording makes it probable computer use.
    static let computerUseWindow: TimeInterval = 3600

    /// Newest first.
    public static func build(store: EventStore, catalog: AIClientCatalog, query: AITimelineQuery,
                             locks: ScreenLockSpans = ScreenLockSpans([]), now: Date = Date()) throws -> [AIActivity] {
        let kinds = query.kinds ?? Set(AIActivity.Kind.allCases)
        var activities: [AIActivity] = []

        if kinds.contains(.sensor) {
            let apps = try sensorApps(store: store, catalog: catalog, clients: query.clients)
            if !apps.isEmpty {
                let sessions = try store.sessions(SessionQuery(apps: Set(apps.keys), since: query.since, limit: query.limit))
                let controls = try store.aiAccess(AIAccessQuery(
                    clients: Set(apps.values), kinds: [.permission],
                    since: query.since?.addingTimeInterval(-computerUseWindow), limit: 100_000))
                    .filter { mouseAndKeyboard.contains($0.detail) && $0.isAllowed }
                for session in sessions {
                    if let until = query.until, session.startedAt >= until { continue }
                    guard let client = apps[session.app] else { continue }
                    var activity = AIActivity(
                        id: "s\(session.id)", client: client, kind: .sensor, start: session.startedAt,
                        end: session.endedAt, detail: session.sensor.rawValue, app: session.app, accessor: "",
                        binaryPath: "", authValue: nil, preflight: false, count: 1, approximate: false)
                    let span = DateInterval(start: session.startedAt, end: max(session.endedAt ?? now, session.startedAt))
                    activity.whileLocked = locks.overlap(with: span) >= ScreenLockSpans.minimumOverlap
                    if session.sensor == .screen {
                        activity.isProbablyComputerUse = controls.contains { row in
                            row.client == client && row.firstSeen <= span.end.addingTimeInterval(computerUseWindow)
                                && row.lastSeen >= span.start.addingTimeInterval(-computerUseWindow)
                        }
                    }
                    activities.append(activity)
                }
            }
        }

        let rowKinds = Set(kinds.compactMap { kind -> AIAccessKind? in
            switch kind {
            case .sensor: nil
            case .permission: .permission
            case .admin: .admin
            }
        })
        if !rowKinds.isEmpty {
            let firstAllowed = try store.aiFirstAllowed()
            let rows = try store.aiAccess(AIAccessQuery(clients: query.clients, kinds: rowKinds,
                                                        includePreflight: query.includePreflight,
                                                        since: query.since, until: query.until, limit: query.limit))
            for row in rows {
                var activity = AIActivity(
                    id: "a" + row.id, client: row.client, kind: row.kind == .admin ? .admin : .permission,
                    start: row.firstSeen, end: row.lastSeen, detail: row.detail, app: row.app, accessor: row.accessor,
                    binaryPath: row.binaryPath, authValue: row.authValue, preflight: row.preflight, count: row.count,
                    approximate: row.approximate)
                activity.isFirstTime = row.kind == .permission && row.isAllowed
                    && firstAllowed[row.client]?[row.detail] == row.firstSeen
                activity.whileLocked = locks.contains(row.firstSeen) || locks.contains(row.lastSeen)
                activities.append(activity)
            }
        }

        return Array(activities.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }.prefix(query.limit))
    }

    /// Identifiers with sensor sessions, mapped to their client.
    static func sensorApps(store: EventStore, catalog: AIClientCatalog, clients: Set<String>?) throws -> [String: String] {
        var result: [String: String] = [:]
        for app in try store.sessionApps() {
            guard let client = catalog.client(identifier: app) else { continue }
            if let clients, !clients.contains(client.id) { continue }
            result[app] = client.id
        }
        return result
    }
}

/// What each AI client did in a day or week, for the Summary tab.
public struct AIReport: Sendable, Equatable {
    public struct ClientUsage: Sendable, Equatable, Identifiable {
        public let client: String
        /// Time per sensor inside the interval, longest first.
        public let sensors: [(sensor: Sensor, duration: TimeInterval)]
        /// Services the client was allowed for the first time in the interval.
        public let newAccess: [String]
        public let checks: Int
        public let adminGrants: Int
        public var id: String { client }

        public static func == (lhs: ClientUsage, rhs: ClientUsage) -> Bool {
            lhs.client == rhs.client && lhs.newAccess == rhs.newAccess && lhs.checks == rhs.checks
                && lhs.adminGrants == rhs.adminGrants
                && lhs.sensors.map(\.sensor) == rhs.sensors.map(\.sensor)
                && lhs.sensors.map(\.duration) == rhs.sensors.map(\.duration)
        }
    }

    /// Most active first.
    public let clients: [ClientUsage]

    public static func build(store: EventStore, catalog: AIClientCatalog, interval: DateInterval,
                             now: Date = Date()) throws -> AIReport {
        let end = min(interval.end, now)
        var sensorTime: [String: [Sensor: TimeInterval]] = [:]
        let apps = try AITimeline.sensorApps(store: store, catalog: catalog, clients: nil)
        if !apps.isEmpty {
            for session in try store.sessions(SessionQuery(apps: Set(apps.keys), since: interval.start, limit: 100_000)) {
                guard let client = apps[session.app], session.startedAt < end else { continue }
                let start = max(session.startedAt, interval.start)
                let stop = min(session.endedAt ?? now, end)
                guard stop > start else { continue }
                sensorTime[client, default: [:]][session.sensor, default: 0] += stop.timeIntervalSince(start)
            }
        }
        var checks: [String: Int] = [:]
        var admin: [String: Int] = [:]
        for row in try store.aiAccess(AIAccessQuery(includePreflight: false, since: interval.start, until: end, limit: 100_000)) {
            if row.kind == .admin { admin[row.client, default: 0] += row.count } else { checks[row.client, default: 0] += row.count }
        }
        var newAccess: [String: [String]] = [:]
        for (client, services) in try store.aiFirstAllowed() {
            let new = services.filter { interval.start <= $0.value && $0.value < end }.keys.sorted()
            if !new.isEmpty { newAccess[client] = new }
        }

        let ids = Set(sensorTime.keys).union(checks.keys).union(admin.keys).union(newAccess.keys)
        let clients = ids.map { id in
            ClientUsage(client: id,
                        sensors: (sensorTime[id] ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                            .map { (sensor: $0.key, duration: $0.value) },
                        newAccess: newAccess[id] ?? [], checks: checks[id] ?? 0, adminGrants: admin[id] ?? 0)
        }
        func weight(_ usage: ClientUsage) -> Double {
            usage.sensors.reduce(0) { $0 + $1.duration } + Double(usage.checks + usage.adminGrants)
        }
        let order = catalog.clients.map(\.id)
        return AIReport(clients: clients.sorted {
            weight($0) == weight($1) ? (order.firstIndex(of: $0.client) ?? .max) < (order.firstIndex(of: $1.client) ?? .max)
                : weight($0) > weight($1)
        })
    }
}
