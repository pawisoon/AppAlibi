import XCTest
@testable import AlibiKit

final class AlertAndReportTests: XCTestCase {
    var url: URL!
    var store: EventStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibi-tests-\(UUID().uuidString)")
            .appendingPathComponent("alibi.sqlite")
        store = try EventStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    let base = Date(timeIntervalSince1970: 1_791_500_000)
    let teamsCam = Attribution(sensor: .camera, app: "com.microsoft.teams2")
    let teamsMic = Attribution(sensor: .microphone, app: "com.microsoft.teams2")
    let notApple: (String, String?) -> Bool = { id, _ in !id.hasPrefix("com.apple.") && id.contains(".") }

    private func sensor(_ kind: SensorEvent.Kind, _ attribution: Attribution, _ seconds: TimeInterval) -> CollectedEvent {
        .sensor(SensorEvent(kind: kind, attribution: attribution, date: base.addingTimeInterval(seconds)))
    }

    private func tcc(_ seconds: TimeInterval, app: String = "com.example.Spy", service: String = "kTCCServiceSystemPolicyDesktopFolder",
                     preflight: Bool = false, authValue: Int = 2) -> CollectedEvent {
        .tcc(TCCAccessEvent(date: base.addingTimeInterval(seconds), service: service, preflight: preflight, authValue: authValue,
                            responsible: TCCProcess(identifier: app, pid: 1, binaryPath: "/Applications/Spy.app/Contents/MacOS/Spy"),
                            accessing: nil))
    }

    /// Stores the batch, then asks the planner, the same order the app uses.
    private func alerts(_ events: [CollectedEvent], _ settings: AlertSettings, at seconds: TimeInterval) throws -> [AccessAlert] {
        try store.record(events, lastProcessed: nil)
        return try AlertPlanner(store: store, settings: settings, isApp: notApple)
            .alerts(for: events, now: base.addingTimeInterval(seconds))
    }

    // MARK: Alerts

    func testCameraAndMicStartingTogetherIsOneAlert() throws {
        let result = try alerts([sensor(.started, teamsCam, 0), sensor(.started, teamsMic, 0)],
                                AlertSettings(sensors: .everyUse), at: 1)
        XCTAssertEqual(result, [.sensors(app: "com.microsoft.teams2", sensors: [.camera, .microphone], firstUse: true, date: base)])
    }

    func testFirstUseModeSkipsLaterSessions() throws {
        let settings = AlertSettings(sensors: .firstUse)
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 0)], settings, at: 1).count, 1)
        _ = try alerts([sensor(.ended, teamsCam, 60)], settings, at: 61)
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 600)], settings, at: 601), [])
        XCTAssertEqual(try alerts([sensor(.started, teamsMic, 700)], settings, at: 701).count, 1, "first use is per sensor")
    }

    func testQuickRestartDoesNotAlertAgain() throws {
        let settings = AlertSettings(sensors: .everyUse)
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 0)], settings, at: 0).count, 1)
        _ = try alerts([sensor(.ended, teamsCam, 10)], settings, at: 10)
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 12)], settings, at: 12), [], "within the merge gap")
        _ = try alerts([sensor(.ended, teamsCam, 100)], settings, at: 100)
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 400)], settings, at: 400).count, 1)
    }

    func testCatchUpAndSystemServicesAndLocationAreQuiet() throws {
        let settings = AlertSettings(sensors: .everyUse, firstPermissionUse: true)
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 0), tcc(0)], settings, at: 3_600), [], "old events")
        let quiet = [
            sensor(.started, Attribution(sensor: .microphone, app: "com.apple.siri"), 5_000),
            sensor(.started, Attribution(sensor: .location, app: "com.example.Maps"), 5_000),
        ]
        XCTAssertEqual(try alerts(quiet, settings, at: 5_000), [])
    }

    func testPermissionAlertOnlyOnFirstRealCheck() throws {
        let settings = AlertSettings(firstPermissionUse: true)
        XCTAssertEqual(try alerts([tcc(0, preflight: true)], settings, at: 0), [], "preflight is not access")
        let first = try alerts([tcc(10), tcc(11)], settings, at: 12)
        XCTAssertEqual(first.count, 1)
        if case .permission(let app, _, let service, let authValue, _) = first.first {
            XCTAssertEqual(app, "com.example.Spy")
            XCTAssertEqual(service, "kTCCServiceSystemPolicyDesktopFolder")
            XCTAssertEqual(authValue, 2)
        } else {
            XCTFail("expected a permission alert")
        }
        XCTAssertEqual(try alerts([tcc(20)], settings, at: 20), [])
        XCTAssertEqual(try alerts([tcc(30, service: "kTCCServiceAddressBook", authValue: 0)], settings, at: 30).count, 1)
    }

    func testDisabledSettingsProduceNothing() throws {
        XCTAssertEqual(try alerts([sensor(.started, teamsCam, 0), tcc(0)], AlertSettings(), at: 0), [])
    }

    // MARK: Report

    func testReportClipsSessionsAndSplitsResults() throws {
        try store.record([
            sensor(.started, teamsCam, -600),       // started 10 minutes before the interval
            sensor(.started, teamsMic, 0),
            sensor(.ended, teamsCam, 1_200),
            sensor(.ended, teamsMic, 1_800),
            sensor(.started, Attribution(sensor: .location, app: "com.example.Maps"), 0),
            sensor(.started, Attribution(sensor: .camera, app: "com.apple.FaceTime"), 0),
            tcc(100), tcc(200), tcc(300, authValue: 0), tcc(400, preflight: true),
        ], lastProcessed: nil)

        let interval = DateInterval(start: base, end: base.addingTimeInterval(3_600))
        let report = try ActivityReport.build(store: store, interval: interval, now: base.addingTimeInterval(7_200), isApp: notApple)

        XCTAssertEqual(report.sensors.map(\.sensor), [.microphone, .camera])
        XCTAssertEqual(report.sensors.first?.duration, 1_800)
        XCTAssertEqual(report.sensors.last?.duration, 1_200)
        XCTAssertEqual(report.sensorApps, ["com.microsoft.teams2"])
        XCTAssertEqual(report.permissions.count, 1)
        XCTAssertEqual(report.permissions.first?.allowed, 2)
        XCTAssertEqual(report.permissions.first?.denied, 1)
        XCTAssertEqual(report.deniedChecks, 1)
    }

    func testCallWithCameraAndMicCountsOnceAndFillsTimeline() throws {
        try store.record([
            sensor(.started, teamsCam, 0), sensor(.started, teamsMic, 0),
            sensor(.ended, teamsCam, 3_000), sensor(.ended, teamsMic, 4_200),
        ], lastProcessed: nil)
        let interval = DateInterval(start: base, end: base.addingTimeInterval(3 * 3_600))
        let report = try ActivityReport.build(store: store, interval: interval, now: base.addingTimeInterval(5_000),
                                              bucket: .hour, isApp: notApple)
        XCTAssertEqual(report.apps.map(\.app), ["com.microsoft.teams2"])
        XCTAssertEqual(report.apps.first?.duration, 4_200, "camera and mic overlap, so the call is 70 minutes")
        XCTAssertEqual(report.apps.first?.sensors, [.camera, .microphone])
        XCTAssertEqual(report.activeTime, 4_200)
        XCTAssertEqual(report.total(for: .camera), 3_000)
        XCTAssertEqual(report.timeline.map(\.duration), [3_600, 600, 0], "the full interval, including what is ahead")
    }

    func testMergeJoinsOverlaps() {
        let spans = [(0, 10), (5, 20), (30, 40), (40, 50)].map {
            DateInterval(start: base.addingTimeInterval(TimeInterval($0.0)), end: base.addingTimeInterval(TimeInterval($0.1)))
        }
        XCTAssertEqual(ActivityReport.merge(spans).map(\.duration), [20, 20])
    }

    func testReportCountsOpenSessionsUpToNow() throws {
        try store.record([sensor(.started, teamsCam, 0)], lastProcessed: nil)
        let interval = DateInterval(start: base, end: base.addingTimeInterval(86_400))
        let report = try ActivityReport.build(store: store, interval: interval, now: base.addingTimeInterval(90), isApp: notApple)
        XCTAssertEqual(report.sensors.first?.duration, 90)
        XCTAssertEqual(report.interval.end, base.addingTimeInterval(90))
    }

    // MARK: Schedule

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // October 2026: the 9th is a Friday.
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testDailyScheduleIsDueOncePerDay() {
        let schedule = ReportSchedule(period: .day, minuteOfDay: 18 * 60)
        XCTAssertNil(schedule.due(now: date(9, 17, 59), lastDelivered: date(8, 18), calendar: calendar))
        XCTAssertEqual(schedule.due(now: date(9, 18), lastDelivered: date(8, 18), calendar: calendar), date(9, 18))
        XCTAssertNil(schedule.due(now: date(9, 18, 5), lastDelivered: date(9, 18), calendar: calendar))
        XCTAssertEqual(schedule.due(now: date(9, 22), lastDelivered: nil, calendar: calendar), date(9, 18), "woke up later that evening")
        XCTAssertNil(schedule.due(now: date(10, 8), lastDelivered: date(8, 18), calendar: calendar), "too late, skip")
    }

    func testWeeklyScheduleWaitsForItsWeekday() {
        let schedule = ReportSchedule(period: .week, minuteOfDay: 18 * 60, weekday: 6)
        XCTAssertEqual(schedule.lastOccurrence(before: date(14, 12), calendar: calendar), date(9, 18))
        XCTAssertNil(schedule.due(now: date(14, 18), lastDelivered: date(9, 18), calendar: calendar))
        XCTAssertEqual(schedule.due(now: date(16, 18, 1), lastDelivered: date(9, 18), calendar: calendar), date(16, 18))
    }

    func testPeriodIntervals() {
        XCTAssertEqual(ReportPeriod.day.interval(endingAt: date(9, 18), calendar: calendar).start, date(9, 0))
        XCTAssertEqual(ReportPeriod.week.interval(endingAt: date(9, 18), calendar: calendar).start, date(3, 0))
    }
}
