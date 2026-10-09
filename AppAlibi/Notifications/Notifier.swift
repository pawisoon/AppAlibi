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
        case permissions
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
            content.title = "\(name) is using your \(list)"
            content.body = firstUse
                ? "The first time AppAlibi has seen this app do that. Started \(Formatting.time(date))."
                : "Started \(Formatting.time(date))."
            content.threadIdentifier = "sensors"
            content.userInfo = ["open": "sensors"]
        case let .permission(app, binaryPath, service, authValue, _):
            let name = AppInfo.info(for: app, binaryPath: binaryPath.isEmpty ? nil : binaryPath).name
            let what = TCCService.displayName(for: service)
            content.title = switch authValue {
            case 0: "\(name) was denied \(what)"
            case 2, 3: "\(name) accessed \(what)"
            default: "\(name) asked for \(what)"
            }
            content.body = "The first time AppAlibi has seen this app do that."
            content.threadIdentifier = "permissions"
            content.userInfo = ["open": "permissions"]
        }
        content.sound = .default
        deliver(content)
    }

    func post(_ report: ActivityReport, period: ReportPeriod) {
        let content = UNMutableNotificationContent()
        content.title = period == .day ? "Your day in AppAlibi" : "Your week in AppAlibi"
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
            lines.append("No app used your camera, microphone or screen.")
        } else {
            let top = apps.prefix(3).map { "\(AppInfo.info(for: $0.app).name) \(Formatting.duration($0.duration))" }
            let more = apps.count > 3 ? ", +\(apps.count - 3) more" : ""
            lines.append("Camera, mic or screen: \(top.joined(separator: ", "))\(more)")
        }
        let permissionApps = report.permissionApps.count
        if permissionApps > 0 {
            let denied = report.deniedChecks
            let apps = permissionApps == 1 ? "1 app" : "\(permissionApps) apps"
            lines.append("Protected data: \(apps)" + (denied > 0 ? ", \(denied) denied" : ""))
        }
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
        case "summary": .summary((info["period"] as? String).flatMap(ReportPeriod.init(rawValue:)) ?? .day)
        default: .sensors
        }
        await MainActor.run { Notifier.shared.open?(destination) }
    }
}
