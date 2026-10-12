import AlibiKit
import AppKit
import Observation
import UserNotifications
import os

/// Posts access alerts and summaries, and routes a click on one back into the app.
@MainActor
@Observable
final class Notifier: NSObject {
    static let shared = Notifier()

    /// Where a click on a notification should take the user.
    enum Destination: Equatable {
        case sensors
        /// Sensors, filtered to use while the screen was locked.
        case lockedUse
        case permissions
        case admin
        /// The AI tab, filtered to one client if given.
        case ai(String?)
        case summary(ReportPeriod)
    }

    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Set by the app delegate, which owns the windows.
    @ObservationIgnored var open: ((Destination) -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let logger = Logger(subsystem: "com.szydlowsky.AppAlibi", category: "Notifier")

    private override init() {
        super.init()
    }

    /// Must run before launch finishes, or a click that launched the app is lost.
    func install() {
        center.delegate = self
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        status = await center.notificationSettings().authorizationStatus
    }

    var isDenied: Bool { status == .denied }

    var isAuthorized: Bool { [.authorized, .provisional].contains(status) }

    /// Asks once. Later calls only read the current answer.
    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification authorization failed: \(String(describing: error))")
        }
        await refreshStatus()
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.szydlowsky.AppAlibi"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Posting

    func post(_ alert: AccessAlert) {
        let content = UNMutableNotificationContent()
        switch alert {
        case let .sensors(app, sensors, firstUse, date):
            let name = AppInfo.info(for: app).name
            let list = ListFormatter.localizedString(byJoining: sensors.map { $0.displayName.lowercased() })
            content.title = String(localized: "\(name) is using your \(list)")
            content.body = firstUse
                ? String(localized: "The first time AppAlibi has seen this app do that. Started \(Formatting.time(date)).")
                : String(localized: "Started \(Formatting.time(date)).")
            content.threadIdentifier = "sensors"
            content.userInfo = ["open": "sensors"]
        case let .permission(app, binaryPath, service, authValue, _):
            let name = AppInfo.info(for: app, binaryPath: binaryPath.isEmpty ? nil : binaryPath).name
            let what = TCCService.displayName(for: service)
            content.title = switch authValue {
            case 0: String(localized: "\(name) was denied \(what)")
            case 2, 3: String(localized: "\(name) accessed \(what)")
            default: String(localized: "\(name) asked for \(what)")
            }
            content.body = String(localized: "The first time AppAlibi has seen this app do that.")
            content.threadIdentifier = "permissions"
            content.userInfo = ["open": "permissions"]
        case let .lockedUse(lock, apps):
            content.title = String(localized: "Used while your Mac was locked")
            content.body = Self.lockedUseText(lock: lock, apps: apps)
            content.threadIdentifier = "locked"
            content.userInfo = ["open": "locked"]
        case let .adminRights(app, rights, date):
            let name = AppInfo.info(for: (app as NSString).lastPathComponent, binaryPath: app).name
            content.title = String(localized: "\(name) got administrator rights")
            let list = ListFormatter.localizedString(byJoining: rights.map(AdminRight.displayName(for:)))
            content.body = String(localized: "\(list), \(Formatting.time(date)).")
            content.threadIdentifier = "admin"
            content.userInfo = ["open": "admin"]
        case let .aiFirstAccess(client, _, _, service, date):
            let name = Self.clientName(client)
            content.title = String(localized: "\(name) got \(TCCService.displayName(for: service))")
            content.body = String(localized: "The first time AppAlibi has seen this AI client allowed that. \(Formatting.time(date)).")
            content.threadIdentifier = "ai"
            content.userInfo = ["open": "ai", "client": client]
        case let .aiAdminRights(client, _, rights, date):
            content.title = String(localized: "\(Self.clientName(client)) got administrator rights")
            let list = ListFormatter.localizedString(byJoining: rights.map(AdminRight.displayName(for:)))
            content.body = String(localized: "\(list), \(Formatting.time(date)).")
            content.threadIdentifier = "ai"
            content.userInfo = ["open": "ai", "client": client]
        case let .aiLockedUse(lock, clients):
            content.title = String(localized: "AI clients were active while your Mac was locked")
            content.body = Self.aiLockedUseText(lock: lock, clients: clients)
            content.threadIdentifier = "ai"
            content.userInfo = clients.count == 1 ? ["open": "ai", "client": clients[0].client] : ["open": "ai"]
        case let .fullDiskAccess(app, binaryPath, date):
            let name = AppInfo.info(for: app, binaryPath: binaryPath.isEmpty ? nil : binaryPath).name
            content.title = String(localized: "\(name) has Full Disk Access")
            content.body = String(localized: "The first time AppAlibi has seen macOS allow it. It can read all your files. \(Formatting.time(date)).")
            content.threadIdentifier = "permissions"
            content.userInfo = ["open": "permissions"]
        }
        content.sound = .default
        deliver(content)
    }

    func post(_ report: ActivityReport, period: ReportPeriod) {
        let content = UNMutableNotificationContent()
        content.title = period == .day ? String(localized: "Your day in AppAlibi") : String(localized: "Your week in AppAlibi")
        content.body = Self.summaryText(report)
        content.threadIdentifier = "summary"
        content.userInfo = ["open": "summary", "period": period.rawValue]
        deliver(content)
    }

    /// Two short lines: who used the sensors, and who reached for protected data.
    static func summaryText(_ report: ActivityReport) -> String {
        var lines: [String] = []
        let apps = report.apps
        if apps.isEmpty {
            lines.append(String(localized: "No app used your camera, microphone or screen."))
        } else {
            let top = apps.prefix(3).map { "\(AppInfo.info(for: $0.app).name) \(Formatting.duration($0.duration))" }
            var names = top
            if apps.count > 3 { names.append(String(localized: "+\(apps.count - 3) more")) }
            lines.append(String(localized: "Camera, mic or screen: \(names.joined(separator: ", "))"))
        }
        let permissionApps = report.permissionApps.count
        if permissionApps > 0 {
            let denied = report.deniedChecks
            lines.append(denied > 0
                ? String(localized: "Apps reaching for protected data: \(permissionApps), checks denied: \(denied)")
                : String(localized: "Apps reaching for protected data: \(permissionApps)"))
        }
        return lines.joined(separator: "\n")
    }

    private static func clientName(_ id: String) -> String {
        AppModel.shared.aiClient(id: id)?.name ?? id
    }

    /// One line per client, then when the screen was locked.
    static func aiLockedUseText(lock: DateInterval, clients: [AILockedUse]) -> String {
        var lines = clients.prefix(3).map { use in
            let what = use.sensors.map { $0.displayName.lowercased() } + use.services.map { TCCService.displayName(for: $0) }
            return "\(clientName(use.client)): \(ListFormatter.localizedString(byJoining: what))"
        }
        if clients.count > 3 { lines.append(String(localized: "+\(clients.count - 3) more")) }
        lines.append(String(localized: "Locked \(Formatting.time(lock.start)) to \(Formatting.time(lock.end))."))
        return lines.joined(separator: "\n")
    }

    /// One line per app, longest first, then when the screen was locked.
    static func lockedUseText(lock: DateInterval, apps: [ActivityReport.AppUsage]) -> String {
        var lines = apps.prefix(3).map { usage in
            let sensors = ListFormatter.localizedString(byJoining: usage.sensors.map { $0.displayName.lowercased() })
            return "\(AppInfo.info(for: usage.app).name): \(sensors), \(Formatting.duration(usage.duration))"
        }
        if apps.count > 3 { lines.append(String(localized: "+\(apps.count - 3) more")) }
        lines.append(String(localized: "Locked \(Formatting.time(lock.start)) to \(Formatting.time(lock.end))."))
        return lines.joined(separator: "\n")
    }

    private func deliver(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [logger] error in
            if let error { logger.error("Posting a notification failed: \(String(describing: error))") }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners even while AppAlibi is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let destination: Destination = switch info["open"] as? String {
        case "permissions": .permissions
        case "locked": .lockedUse
        case "admin": .admin
        case "ai": .ai(info["client"] as? String)
        case "summary": .summary((info["period"] as? String).flatMap(ReportPeriod.init(rawValue:)) ?? .day)
        default: .sensors
        }
        await MainActor.run { Notifier.shared.open?(destination) }
    }
}
