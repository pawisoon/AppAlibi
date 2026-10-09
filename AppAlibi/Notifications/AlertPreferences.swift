import AlibiKit
import Foundation

/// Notification and summary settings. Plain UserDefaults keys, so Settings can
/// bind with `@AppStorage` and the model and scheduler read the same values.
enum AlertPreferences {
    static let sensorsKey = "appalibi.alerts.sensors"
    static let firstPermissionKey = "appalibi.alerts.firstPermission"
    static let lockedUseKey = "appalibi.alerts.lockedUse"
    static let dailyKey = "appalibi.reports.daily"
    static let weeklyKey = "appalibi.reports.weekly"
    static let minuteKey = "appalibi.reports.minuteOfDay"
    static let weekdayKey = "appalibi.reports.weekday"

    /// End of the working day.
    static let defaultMinute = 18 * 60
    /// Friday, as in `Calendar`.
    static let defaultWeekday = 6

    private static var defaults: UserDefaults { .standard }

    static var alertSettings: AlertSettings {
        AlertSettings(
            sensors: defaults.string(forKey: sensorsKey).flatMap(SensorAlertMode.init(rawValue:)) ?? .off,
            firstPermissionUse: defaults.bool(forKey: firstPermissionKey),
            lockedUse: defaults.bool(forKey: lockedUseKey)
        )
    }

    static func isEnabled(_ period: ReportPeriod) -> Bool {
        defaults.bool(forKey: period == .day ? dailyKey : weeklyKey)
    }

    static func schedule(for period: ReportPeriod) -> ReportSchedule {
        let minute = defaults.object(forKey: minuteKey) as? Int ?? defaultMinute
        let weekday = defaults.object(forKey: weekdayKey) as? Int ?? defaultWeekday
        return ReportSchedule(period: period, minuteOfDay: minute, weekday: weekday)
    }

    static func lastDelivered(_ period: ReportPeriod) -> Date? {
        defaults.object(forKey: lastDeliveredKey(period)) as? Date
    }

    /// Also called when a summary is switched on, so one whose time already
    /// passed today does not arrive the moment the switch is flipped.
    static func setLastDelivered(_ date: Date, for period: ReportPeriod) {
        defaults.set(date, forKey: lastDeliveredKey(period))
    }

    private static func lastDeliveredKey(_ period: ReportPeriod) -> String {
        "appalibi.reports.lastDelivered.\(period.rawValue)"
    }

    /// What the welcome tour's "Turn On Notifications" switches on.
    static func enableDefaults() {
        defaults.set(SensorAlertMode.firstUse.rawValue, forKey: sensorsKey)
        defaults.set(true, forKey: lockedUseKey)
        defaults.set(true, forKey: dailyKey)
        setLastDelivered(Date(), for: .day)
    }

    /// Undoes `enableDefaults` when the user declines the system prompt.
    static func disableAll() {
        defaults.set(SensorAlertMode.off.rawValue, forKey: sensorsKey)
        defaults.set(false, forKey: firstPermissionKey)
        defaults.set(false, forKey: lockedUseKey)
        defaults.set(false, forKey: dailyKey)
        defaults.set(false, forKey: weeklyKey)
    }

    static var wantsNotifications: Bool {
        alertSettings.isEnabled || ReportPeriod.allCases.contains(where: isEnabled)
    }
}

extension SensorAlertMode {
    var title: String {
        switch self {
        case .off: "Off"
        case .firstUse: "First time an app uses one"
        case .everyUse: "Every time"
        }
    }
}

extension ReportPeriod {
    var title: String {
        switch self {
        case .day: "Today"
        case .week: "Last 7 Days"
        }
    }
}
