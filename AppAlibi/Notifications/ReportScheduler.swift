import AlibiKit
import AppKit

/// Delivers the daily and weekly summaries. Checks once a minute and on wake
/// instead of arming one long timer, so a Mac that slept through the time
/// still gets the summary when it wakes (within `ReportSchedule.grace`).
@MainActor
final class ReportScheduler {
    static let shared = ReportScheduler()

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ReportScheduler.shared.check() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ReportScheduler.shared.check() }
        }
        check()
    }

    func check(now: Date = Date()) {
        for period in ReportPeriod.allCases where AlertPreferences.isEnabled(period) {
            let schedule = AlertPreferences.schedule(for: period)
            guard let occurrence = schedule.due(now: now, lastDelivered: AlertPreferences.lastDelivered(period)) else { continue }
            AlertPreferences.setLastDelivered(now, for: period)
            // Late on the same day, the summary includes the extra hours. After
            // midnight it stops at the scheduled time, so it is still about that day.
            let end = Calendar.current.isDate(now, inSameDayAs: occurrence) ? now : occurrence
            send(period, endingAt: end)
        }
    }

    /// Also used by the "Send Now" button in Settings.
    func send(_ period: ReportPeriod, endingAt end: Date = Date()) {
        guard let report = AppModel.shared.report(period.interval(endingAt: end), now: end) else { return }
        Notifier.shared.post(report, period: period)
    }
}
