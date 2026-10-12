import Foundation

/// When to tell the user that an app started using a sensor.
public enum SensorAlertMode: String, CaseIterable, Sendable {
    case off
    /// The first recorded use of a sensor by an app.
    case firstUse
    /// Every new session.
    case everyUse
}

public struct AlertSettings: Sendable, Equatable {
    public var sensors: SensorAlertMode
    /// The first real (not preflight) permission check by an app for a service.
    public var firstPermissionUse: Bool
    /// On unlock: what used the camera, microphone or screen while the screen was locked.
    public var lockedUse: Bool
    /// Every time an app (not a system service) is granted an admin right.
    public var adminRights: Bool
    /// AI clients: a control service allowed for the first time, an admin grant,
    /// and use of the camera, microphone, screen or input while the screen was locked.
    public var aiClients: Bool
    /// The first time tccd allows an app Full Disk Access.
    public var fullDiskAccess: Bool

    public init(sensors: SensorAlertMode = .off, firstPermissionUse: Bool = false, lockedUse: Bool = false,
                adminRights: Bool = false, aiClients: Bool = false, fullDiskAccess: Bool = false) {
        self.sensors = sensors
        self.firstPermissionUse = firstPermissionUse
        self.lockedUse = lockedUse
        self.adminRights = adminRights
        self.aiClients = aiClients
        self.fullDiskAccess = fullDiskAccess
    }

    public var isEnabled: Bool {
        sensors != .off || firstPermissionUse || lockedUse || adminRights || aiClients || fullDiskAccess
    }
}

/// What one AI client did while the screen was locked.
public struct AILockedUse: Equatable, Sendable {
    public let client: String
    /// In `Sensor.known` order.
    public let sensors: [Sensor]
    /// TCC services with real checks inside the lock, sorted.
    public let services: [String]

    public init(client: String, sensors: [Sensor], services: [String]) {
        self.client = client
        self.sensors = sensors
        self.services = services
    }
}

public enum AccessAlert: Equatable, Sendable {
    /// An app started one or more sensors at once (Teams turns on camera and mic together).
    case sensors(app: String, sensors: [Sensor], firstUse: Bool, date: Date)
    case permission(app: String, binaryPath: String, service: String, authValue: Int, date: Date)
    /// Posted on unlock. Apps longest first; each duration is the part inside the lock.
    case lockedUse(lock: DateInterval, apps: [ActivityReport.AppUsage])
    /// An app was granted admin rights. `app` is a path; rights in the order granted, without repeats.
    case adminRights(app: String, rights: [String], date: Date)
    /// An AI client was allowed a control service (`EventStore.controlServices`) for the first time.
    case aiFirstAccess(client: String, app: String, binaryPath: String, service: String, date: Date)
    /// An AI client was granted admin rights. `app` is a path.
    case aiAdminRights(client: String, app: String, rights: [String], date: Date)
    /// Posted on unlock.
    case aiLockedUse(lock: DateInterval, clients: [AILockedUse])
    /// tccd allowed an app Full Disk Access for the first time.
    case fullDiskAccess(app: String, binaryPath: String, date: Date)
}

/// Decides which freshly stored events deserve a notification. Runs after the
/// batch is in the store, so the store already counts the events themselves.
public struct AlertPlanner {
    public let store: EventStore
    public let settings: AlertSettings
    /// Events older than this are history being caught up on, not news.
    public var maxAge: TimeInterval = 120
    public var minimumLockedUse = ScreenLockSpans.minimumOverlap
    /// Whether an identifier (and the binary tccd logged, if any) is an app rather
    /// than a system service. The app side knows where bundles live.
    public let isApp: (_ identifier: String, _ binaryPath: String?) -> Bool

    public init(store: EventStore, settings: AlertSettings,
                isApp: @escaping (_ identifier: String, _ binaryPath: String?) -> Bool) {
        self.store = store
        self.settings = settings
        self.isApp = isApp
    }

    public func alerts(for events: [CollectedEvent], now: Date = Date()) throws -> [AccessAlert] {
        guard settings.isEnabled else { return [] }
        let fresh = events.filter { now.timeIntervalSince($0.date) <= maxAge }
        return try sensorAlerts(fresh) + permissionAlerts(fresh) + lockedUseAlerts(fresh, now: now)
            + adminRightAlerts(fresh) + aiAccessAlerts(fresh) + aiAdminAlerts(fresh) + aiLockedUseAlerts(fresh, now: now)
            + fullDiskAccessAlerts(fresh)
    }

    /// The clients the store tracks, so the alerts and `ai_access` agree.
    private var catalog: AIClientCatalog { store.aiClients }

    /// Services whose real use while locked is worth telling: sensors and input.
    static let lockedServices: Set<String> = [
        "kTCCServiceCamera", "kTCCServiceMicrophone", "kTCCServiceScreenCapture", "kTCCServiceAudioCapture",
        "kTCCServiceListenEvent", "kTCCServicePostEvent", "kTCCServiceAccessibility",
    ]

    private func aiAccessAlerts(_ events: [CollectedEvent]) throws -> [AccessAlert] {
        guard settings.aiClients else { return [] }
        let services = Set(EventStore.controlServices)
        struct Key: Hashable { let client: String; let service: String }
        var inBatch: [Key: Int] = [:]
        var first: [Key: TCCAccessEvent] = [:]
        var order: [Key] = []
        for case .tcc(let event) in events where services.contains(event.service) && (event.authValue == 2 || event.authValue == 3) {
            guard let client = catalog.client(for: event) else { continue }
            let key = Key(client: client.id, service: event.service)
            inBatch[key, default: 0] += 1
            if first[key] == nil {
                first[key] = event
                order.append(key)
            }
        }
        return try order.compactMap { key in
            guard try store.aiAllowedCount(client: key.client, service: key.service) <= inBatch[key]! else { return nil }
            let event = first[key]!
            return .aiFirstAccess(client: key.client, app: event.app, binaryPath: event.binaryPath,
                                  service: key.service, date: event.date)
        }
    }

    private func aiAdminAlerts(_ events: [CollectedEvent]) -> [AccessAlert] {
        guard settings.aiClients else { return [] }
        var byClient: [String: (app: String, rights: [String], date: Date)] = [:]
        var order: [String] = []
        for case .adminRight(let event) in events {
            guard let client = catalog.client(for: event) else { continue }
            if byClient[client.id] == nil {
                order.append(client.id)
                byClient[client.id] = (event.app, [], event.date)
            }
            if !byClient[client.id]!.rights.contains(event.right) { byClient[client.id]!.rights.append(event.right) }
        }
        return order.map { .aiAdminRights(client: $0, app: byClient[$0]!.app, rights: byClient[$0]!.rights, date: byClient[$0]!.date) }
    }

    private func aiLockedUseAlerts(_ events: [CollectedEvent], now: Date) throws -> [AccessAlert] {
        guard settings.aiClients else { return [] }
        var alerts: [AccessAlert] = []
        for case .screenLock(let event) in events where !event.locked {
            guard let lock = try store.screenLock(endingAt: event.date) else { continue }
            let locks = ScreenLockSpans([lock])
            let activities = try AITimeline.build(store: store, catalog: catalog,
                                                  query: AITimelineQuery(kinds: [.sensor, .permission], since: lock.start,
                                                                         until: lock.end, limit: 100_000),
                                                  locks: locks, now: now)
            var sensors: [String: Set<Sensor>] = [:]
            var services: [String: Set<String>] = [:]
            for activity in activities where activity.whileLocked {
                if let sensor = activity.sensor {
                    guard sensor.isSensitive else { continue }
                    sensors[activity.client, default: []].insert(sensor)
                } else if Self.lockedServices.contains(activity.detail), !activity.preflight, !activity.isDenied {
                    services[activity.client, default: []].insert(activity.detail)
                }
            }
            let ids = Set(sensors.keys).union(services.keys)
            let order = catalog.clients.map(\.id)
            let uses = ids.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }.map { id in
                AILockedUse(client: id, sensors: Sensor.known.filter { sensors[id]?.contains($0) == true },
                            services: (services[id] ?? []).sorted())
            }
            if !uses.isEmpty { alerts.append(.aiLockedUse(lock: lock, clients: uses)) }
        }
        return alerts
    }

    /// Apps only: many Apple daemons hold Full Disk Access by design. An AI
    /// client's first grant is already told by `aiAccessAlerts` when that is on.
    private func fullDiskAccessAlerts(_ events: [CollectedEvent]) throws -> [AccessAlert] {
        guard settings.fullDiskAccess else { return [] }
        var inBatch: [String: Int] = [:]
        var first: [String: TCCAccessEvent] = [:]
        var order: [String] = []
        for case .tcc(let event) in events
        where event.service == EventStore.fullDiskAccessService && (event.authValue == 2 || event.authValue == 3) {
            inBatch[event.app, default: 0] += 1
            if first[event.app] == nil {
                first[event.app] = event
                order.append(event.app)
            }
        }
        return try order.compactMap { app in
            let event = first[app]!
            if settings.aiClients, catalog.client(for: event) != nil { return nil }
            guard isApp(app, event.binaryPath.isEmpty ? nil : event.binaryPath),
                  try store.tccAllowedCount(app: app, service: event.service) <= inBatch[app]! else { return nil }
            return .fullDiskAccess(app: app, binaryPath: event.binaryPath, date: event.date)
        }
    }

    /// Unlike the other alerts, system services count: Screen Sharing on a locked
    /// Mac is exactly what this is for. Location does not.
    private func lockedUseAlerts(_ events: [CollectedEvent], now: Date) throws -> [AccessAlert] {
        guard settings.lockedUse else { return [] }
        var alerts: [AccessAlert] = []
        for case .screenLock(let event) in events where !event.locked {
            guard let lock = try store.screenLock(endingAt: event.date) else { continue }
            let report = try ActivityReport.build(store: store, interval: lock, now: now) { _, _ in true }
            let apps = report.apps.filter { $0.duration >= minimumLockedUse }
            if !apps.isEmpty { alerts.append(.lockedUse(lock: lock, apps: apps)) }
        }
        return alerts
    }

    private func sensorAlerts(_ events: [CollectedEvent]) throws -> [AccessAlert] {
        guard settings.sensors != .off else { return [] }
        var byApp: [String: (sensors: [Sensor], firstUse: Bool, date: Date)] = [:]
        var order: [String] = []
        for case .sensor(let event) in events where event.kind == .started {
            let attribution = event.attribution
            guard attribution.sensor.isSensitive, isApp(attribution.app, nil) else { continue }
            let recent = try store.sessions(SessionQuery(sensors: [attribution.sensor], apps: [attribution.app], limit: 2))
            // A start within the merge gap continues the previous session; the
            // user already heard about it.
            guard let current = recent.first, current.startedAt >= event.date.addingTimeInterval(-1) else { continue }
            let firstUse = recent.count == 1
            if settings.sensors == .firstUse, !firstUse { continue }
            if byApp[attribution.app] == nil {
                order.append(attribution.app)
                byApp[attribution.app] = ([], false, event.date)
            }
            byApp[attribution.app]!.sensors.append(attribution.sensor)
            byApp[attribution.app]!.firstUse = byApp[attribution.app]!.firstUse || firstUse
        }
        return order.map { app in
            let entry = byApp[app]!
            return .sensors(app: app, sensors: entry.sensors, firstUse: entry.firstUse, date: entry.date)
        }
    }

    /// One alert per app and batch: an installer takes several rights at once.
    private func adminRightAlerts(_ events: [CollectedEvent]) -> [AccessAlert] {
        guard settings.adminRights else { return [] }
        var byApp: [String: (rights: [String], date: Date)] = [:]
        var order: [String] = []
        for case .adminRight(let event) in events {
            let name = (event.app as NSString).lastPathComponent
            guard isApp(name, event.app) else { continue }
            // Told once, as an AI client's grant.
            if settings.aiClients, catalog.client(for: event) != nil { continue }
            if byApp[event.app] == nil {
                order.append(event.app)
                byApp[event.app] = ([], event.date)
            }
            if !byApp[event.app]!.rights.contains(event.right) { byApp[event.app]!.rights.append(event.right) }
        }
        return order.map { .adminRights(app: $0, rights: byApp[$0]!.rights, date: byApp[$0]!.date) }
    }

    private func permissionAlerts(_ events: [CollectedEvent]) throws -> [AccessAlert] {
        guard settings.firstPermissionUse else { return [] }
        struct Key: Hashable { let app: String; let service: String }
        var inBatch: [Key: Int] = [:]
        var first: [Key: TCCAccessEvent] = [:]
        var order: [Key] = []
        for case .tcc(let event) in events where !event.preflight {
            let key = Key(app: event.app, service: event.service)
            inBatch[key, default: 0] += 1
            if first[key] == nil {
                first[key] = event
                order.append(key)
            }
        }
        var alerts: [AccessAlert] = []
        for key in order {
            let event = first[key]!
            guard isApp(event.app, event.binaryPath.isEmpty ? nil : event.binaryPath) else { continue }
            // Every check in the store came from this batch: nothing before it.
            guard try store.tccAccessCount(app: key.app, service: key.service) <= inBatch[key]! else { continue }
            alerts.append(.permission(app: event.app, binaryPath: event.binaryPath, service: event.service,
                                      authValue: event.authValue, date: event.date))
        }
        return alerts
    }
}

extension CollectedEvent {
    public var date: Date {
        switch self {
        case .sensor(let event): event.date
        case .tcc(let event): event.date
        case .screenLock(let event): event.date
        case .adminRight(let event): event.date
        }
    }
}
