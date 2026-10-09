import Foundation

/// What happened in a stretch of time: sensor use per app and real permission
/// checks per app. Feeds the Summary tab and the daily and weekly notifications.
public struct ActivityReport: Sendable, Equatable {
    public struct SensorUsage: Sendable, Equatable, Identifiable {
        public let app: String
        public let sensor: Sensor
        /// Time in use inside the report's interval. Sessions that cross its edges are clipped.
        public let duration: TimeInterval
        public let sessions: Int
        public var id: String { "\(app)|\(sensor.rawValue)" }
    }

    /// One app across all its sensors. A call with camera and microphone on for
    /// an hour counts as an hour, not two.
    public struct AppUsage: Sendable, Equatable, Identifiable {
        public let app: String
        public let duration: TimeInterval
        /// In `Sensor.known` order.
        public let sensors: [Sensor]
        public var id: String { app }
    }

    /// One bar of the chart: an hour of a day report, or a day of a week report.
    public struct Bucket: Sendable, Equatable, Identifiable {
        public let interval: DateInterval
        /// Time any sensor was in use by any app.
        public let duration: TimeInterval
        public var id: Date { interval.start }
    }

    public struct PermissionUsage: Sendable, Equatable, Identifiable {
        public let app: String
        public let binaryPath: String
        public let service: String
        public let allowed: Int
        public let denied: Int
        public let lastSeen: Date
        public var id: String { "\(app)|\(service)" }
        public var serviceName: String { TCCService.displayName(for: service) }
    }

    public let interval: DateInterval
    /// Longest first.
    public let sensors: [SensorUsage]
    /// Longest first.
    public let apps: [AppUsage]
    /// Time any sensor was in use by any app.
    public let activeTime: TimeInterval
    /// Covers the whole requested interval, including the part still ahead.
    public let timeline: [Bucket]
    /// Most checks first.
    public let permissions: [PermissionUsage]

    public var isEmpty: Bool { sensors.isEmpty && permissions.isEmpty }

    /// Apps that used a sensor, longest first.
    public var sensorApps: [String] { apps.map(\.app) }

    public var permissionApps: [String] {
        var seen = Set<String>()
        return permissions.map(\.app).filter { seen.insert($0).inserted }
    }

    public var deniedChecks: Int { permissions.reduce(0) { $0 + $1.denied } }

    public func total(for sensor: Sensor) -> TimeInterval {
        sensors.filter { $0.sensor == sensor }.reduce(0) { $0 + $1.duration }
    }

    /// - Parameters:
    ///   - bucket: `.hour` or `.day` splits the interval for the chart. nil leaves the timeline empty.
    ///   - includeLocation: Location is left out by default, like the menu, because
    ///     System Services checks it every few minutes.
    ///   - isApp: Keeps apps and drops system services. Pass `{ _, _ in true }` for everything.
    public static func build(
        store: EventStore,
        interval: DateInterval,
        now: Date = Date(),
        bucket: Calendar.Component? = nil,
        calendar: Calendar = .current,
        includeLocation: Bool = false,
        isApp: (_ identifier: String, _ binaryPath: String?) -> Bool
    ) throws -> ActivityReport {
        let end = min(interval.end, now)

        typealias Total = (app: String, sensor: Sensor, duration: TimeInterval, sessions: Int)
        var sensorTotals: [String: Total] = [:]
        var spans: [String: [DateInterval]] = [:]
        var appSensors: [String: Set<Sensor>] = [:]
        for session in try store.sessions(SessionQuery(since: interval.start, limit: 100_000)) {
            guard includeLocation || session.sensor.isSensitive, session.startedAt < end else { continue }
            let start = max(session.startedAt, interval.start)
            let stop = min(session.endedAt ?? now, end)
            guard stop >= start, isApp(session.app, nil) else { continue }
            let key = "\(session.app)|\(session.sensor.rawValue)"
            var total: Total = sensorTotals[key] ?? (session.app, session.sensor, 0, 0)
            total.duration += stop.timeIntervalSince(start)
            total.sessions += 1
            sensorTotals[key] = total
            spans[session.app, default: []].append(DateInterval(start: start, end: stop))
            appSensors[session.app, default: []].insert(session.sensor)
        }
        let sensors = sensorTotals.values
            .map { SensorUsage(app: $0.app, sensor: $0.sensor, duration: $0.duration, sessions: $0.sessions) }
            .sorted { (a: SensorUsage, b: SensorUsage) -> Bool in
                a.duration == b.duration ? a.id < b.id : a.duration > b.duration
            }
        let apps = spans
            .map { app, list -> AppUsage in
                let used = appSensors[app] ?? []
                let ordered = Sensor.known.filter(used.contains) + used.subtracting(Sensor.known).sorted()
                return AppUsage(app: app, duration: length(of: merge(list)), sensors: ordered)
            }
            .sorted { (a: AppUsage, b: AppUsage) -> Bool in
                a.duration == b.duration ? a.app < b.app : a.duration > b.duration
            }
        let all = merge(spans.values.flatMap { $0 })
        let timeline = bucket.map { component in
            buckets(of: interval, by: component, calendar: calendar).map { slot in
                Bucket(interval: slot, duration: length(of: all.compactMap { $0.intersection(with: slot) }))
            }
        } ?? []

        // Rows are per day, so a row counts if its day overlaps the interval.
        var permissionTotals: [String: PermissionUsage] = [:]
        let rows = try store.tccAggregates(TCCQuery(includePreflight: false, includeApple: true,
                                                    since: interval.start, limit: 100_000))
        for row in rows where row.firstSeen < end {
            guard isApp(row.app, row.binaryPath.isEmpty ? nil : row.binaryPath) else { continue }
            let key = "\(row.app)|\(row.service)"
            let old = permissionTotals[key]
            permissionTotals[key] = PermissionUsage(
                app: row.app,
                binaryPath: old?.binaryPath ?? row.binaryPath,
                service: row.service,
                allowed: (old?.allowed ?? 0) + (row.authValue == 0 ? 0 : row.count),
                denied: (old?.denied ?? 0) + (row.authValue == 0 ? row.count : 0),
                lastSeen: max(old?.lastSeen ?? .distantPast, row.lastSeen)
            )
        }
        let permissions = permissionTotals.values.sorted { (a: PermissionUsage, b: PermissionUsage) -> Bool in
            let (left, right) = (a.allowed + a.denied, b.allowed + b.denied)
            return left == right ? a.id < b.id : left > right
        }

        return ActivityReport(
            interval: DateInterval(start: interval.start, end: max(end, interval.start)),
            sensors: sensors, apps: apps, activeTime: length(of: all), timeline: timeline, permissions: permissions
        )
    }

    /// Overlapping or touching spans joined into one.
    static func merge(_ spans: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func length(of spans: [DateInterval]) -> TimeInterval {
        spans.reduce(0) { $0 + $1.duration }
    }

    private static func buckets(of interval: DateInterval, by component: Calendar.Component, calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        var start = interval.start
        while start < interval.end, let next = calendar.date(byAdding: component, value: 1, to: start) {
            result.append(DateInterval(start: start, end: min(next, interval.end)))
            start = next
        }
        return result
    }
}

public enum ReportPeriod: String, CaseIterable, Sendable {
    case day
    case week

    /// The day so far, or the seven days up to `date`. Used by the notifications.
    public func interval(endingAt date: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .day:
            return DateInterval(start: calendar.startOfDay(for: date), end: date)
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: date)) ?? date
            return DateInterval(start: start, end: date)
        }
    }

    /// The whole calendar day or week containing `date`. Used by the Summary tab.
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component = self == .day ? .day : .weekOfYear
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// One bar per hour of a day, or per day of a week.
    public var bucket: Calendar.Component { self == .day ? .hour : .day }
}

/// When a summary is due. The app checks every minute instead of setting one
/// long timer, so a Mac that slept through the time still gets it on wake.
public struct ReportSchedule: Sendable, Equatable {
    public var period: ReportPeriod
    /// Minutes after midnight.
    public var minuteOfDay: Int
    /// 1 is Sunday, as in `Calendar`. Weekly summaries only.
    public var weekday: Int
    /// A summary missed by more than this (the Mac was off all evening) is skipped.
    public var grace: TimeInterval = 6 * 3600

    public init(period: ReportPeriod, minuteOfDay: Int, weekday: Int = 6) {
        self.period = period
        self.minuteOfDay = minuteOfDay
        self.weekday = weekday
    }

    /// The latest scheduled time at or before `now`.
    public func lastOccurrence(before now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let time = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day),
                  time <= now else { continue }
            if period == .week, calendar.component(.weekday, from: day) != weekday { continue }
            return time
        }
        return nil
    }

    /// The occurrence to deliver now, if one passed since `lastDelivered` and is still within grace.
    public func due(now: Date, lastDelivered: Date?, calendar: Calendar = .current) -> Date? {
        guard let occurrence = lastOccurrence(before: now, calendar: calendar),
              now.timeIntervalSince(occurrence) <= grace else { return nil }
        if let lastDelivered, lastDelivered >= occurrence { return nil }
        return occurrence
    }
}
