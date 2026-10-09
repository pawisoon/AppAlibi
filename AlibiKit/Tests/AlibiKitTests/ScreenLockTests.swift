import XCTest
@testable import AlibiKit

final class ScreenLockParserTests: XCTestCase {
    func testParsesRealLockAndUnlockLines() throws {
        XCTAssertEqual(ScreenLockParser.locked(from: Fixtures.screenLocked, userID: 501), true)
        let entry = try XCTUnwrap(LogEntry.parse(Fixtures.screenUnlockedNDJSON))
        XCTAssertEqual(entry.processID, 246)
        XCTAssertEqual(ScreenLockParser.locked(from: entry.eventMessage, userID: 501), false)
    }

    func testIgnoresOtherUsersAndOtherNotifications() {
        XCTAssertNil(ScreenLockParser.locked(from: Fixtures.screenLocked, userID: 502), "Fast User Switching: another session")
        XCTAssertNil(ScreenLockParser.locked(from: Fixtures.screenLockUIShown, userID: 501))
        XCTAssertNil(ScreenLockParser.locked(from: Fixtures.tccResult, userID: 501))
    }

    func testProcessorEmitsChangesOnly() {
        var processor = EventProcessor()
        let locked = Fixtures.entry(Fixtures.screenLocked.replacingOccurrences(of: ":501", with: ":\(getuid())"), at: 0)
        let unlocked = Fixtures.entry(Fixtures.screenLocked
            .replacingOccurrences(of: "screenIsLocked", with: "screenIsUnlocked")
            .replacingOccurrences(of: ":501", with: ":\(getuid())"), at: 60)
        XCTAssertEqual(processor.process(locked), [.screenLock(ScreenLockEvent(locked: true, date: locked.timestamp))])
        XCTAssertEqual(processor.process(locked), [], "already locked")
        XCTAssertEqual(processor.process(unlocked), [.screenLock(ScreenLockEvent(locked: false, date: unlocked.timestamp))])
        XCTAssertTrue(EventProcessor(screenLocked: true).screenLocked)
    }

    func testSpansOverlap() {
        let base = Date(timeIntervalSince1970: 1_000)
        let spans = ScreenLockSpans([
            DateInterval(start: base, duration: 100),
            DateInterval(start: base.addingTimeInterval(300), duration: 100),
        ])
        XCTAssertEqual(spans.overlap(with: DateInterval(start: base.addingTimeInterval(50), duration: 300)), 100)
        XCTAssertEqual(spans.overlap(with: DateInterval(start: base.addingTimeInterval(150), duration: 100)), 0)
    }

    func testBootTimeIsInThePast() throws {
        let boot = try XCTUnwrap(SystemClock.bootTime())
        XCTAssertLessThan(boot, Date())
    }
}

final class ScreenLockStoreTests: XCTestCase {
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
    let zoomMic = Attribution(sensor: .microphone, app: "us.zoom.xos")
    let screenSharing = Attribution(sensor: .screen, app: "com.apple.screensharing.agent")

    private func lock(_ locked: Bool, _ seconds: TimeInterval) -> CollectedEvent {
        .screenLock(ScreenLockEvent(locked: locked, date: base.addingTimeInterval(seconds)))
    }

    private func sensor(_ kind: SensorEvent.Kind, _ attribution: Attribution, _ seconds: TimeInterval) -> CollectedEvent {
        .sensor(SensorEvent(kind: kind, attribution: attribution, date: base.addingTimeInterval(seconds)))
    }

    func testLockLifecycle() throws {
        try store.record([lock(true, 0)], lastProcessed: nil)
        XCTAssertTrue(try store.isScreenLocked())
        XCTAssertEqual(try store.screenLocks(now: base.addingTimeInterval(30)).spans.first?.duration, 30, "open lock runs to now")

        try store.record([lock(true, 10), lock(false, 100), lock(false, 200)], lastProcessed: nil)
        XCTAssertFalse(try store.isScreenLocked())
        XCTAssertEqual(try store.screenLocks().spans, [DateInterval(start: base, duration: 100)], "second lock and unlock ignored")
        XCTAssertEqual(try store.screenLock(endingAt: base.addingTimeInterval(100)), DateInterval(start: base, duration: 100))
        XCTAssertEqual(try store.screenLocks(overlapping: DateInterval(start: base.addingTimeInterval(150), duration: 10)).spans, [])
    }

    func testLockHistoryImportRunsOnce() throws {
        XCTAssertTrue(try store.needsLockHistoryImport())
        try store.markLockHistoryImported()
        store = nil
        store = try EventStore(url: url)
        XCTAssertFalse(try store.needsLockHistoryImport())
    }

    func testLockFromBeforeARestartEndsAtBoot() throws {
        try store.record([lock(true, 0)], lastProcessed: nil)
        try store.endScreenLock(openBefore: base.addingTimeInterval(-10))
        XCTAssertTrue(try store.isScreenLocked(), "locked after the boot: still open")
        try store.endScreenLock(openBefore: base.addingTimeInterval(600))
        XCTAssertFalse(try store.isScreenLocked())
        XCTAssertEqual(try store.screenLocks().spans.first?.duration, 600)
    }

    func testRetentionKeepsWhatCrossesTheCutoff() throws {
        let tcc: (TimeInterval) -> CollectedEvent = { seconds in
            .tcc(TCCAccessEvent(date: self.base.addingTimeInterval(seconds), service: "kTCCServiceAddressBook", preflight: false,
                                authValue: 2, responsible: TCCProcess(identifier: "com.example.Spy", pid: 1, binaryPath: nil), accessing: nil))
        }
        try store.record([
            sensor(.started, zoomMic, 0), sensor(.ended, zoomMic, 100),            // old
            sensor(.started, screenSharing, 0), sensor(.ended, screenSharing, 3 * 86_400),  // crosses the cutoff
            sensor(.started, Attribution(sensor: .camera, app: "com.apple.FaceTime"), 50),  // still open
            lock(true, 0), lock(false, 100),
            tcc(0), tcc(4 * 86_400),
        ], lastProcessed: base)

        let deleted = try store.deleteOlderThan(base.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(deleted, 3)
        XCTAssertEqual(Set(try store.sessions().map(\.app)), ["com.apple.screensharing.agent", "com.apple.FaceTime"])
        XCTAssertEqual(try store.tccAggregates(TCCQuery(includeApple: true)).count, 1)
        XCTAssertEqual(try store.screenLocks().spans, [])
        XCTAssertEqual(try store.lastProcessed(), base, "checkpoint kept")
    }

    // MARK: Alert

    private func alerts(_ events: [CollectedEvent], at seconds: TimeInterval) throws -> [AccessAlert] {
        try store.record(events, lastProcessed: nil)
        return try AlertPlanner(store: store, settings: AlertSettings(lockedUse: true)) { _, _ in false }
            .alerts(for: events, now: base.addingTimeInterval(seconds))
    }

    func testUnlockRecapsUseWhileLocked() throws {
        _ = try alerts([sensor(.started, zoomMic, -600), lock(true, 0)], at: 0)
        _ = try alerts([sensor(.ended, zoomMic, 2), sensor(.started, screenSharing, 1_000), sensor(.ended, screenSharing, 1_300)], at: 1_300)
        XCTAssertEqual(try alerts([sensor(.started, zoomMic, 1_799)], at: 1_799), [], "nothing until the unlock")

        let result = try alerts([lock(false, 1_800)], at: 1_801)
        let lock = DateInterval(start: base, duration: 1_800)
        XCTAssertEqual(result, [.lockedUse(lock: lock, apps: [
            ActivityReport.AppUsage(app: "com.apple.screensharing.agent", duration: 300, sensors: [.screen]),
        ])], "system services count; Zoom letting go 2s after the lock and restarting 1s before the unlock do not")
    }

    func testQuietUnlocks() throws {
        _ = try alerts([lock(true, 0)], at: 0)
        XCTAssertEqual(try alerts([lock(false, 600)], at: 601), [], "nothing used")

        _ = try alerts([lock(true, 1_000), sensor(.started, zoomMic, 1_100)], at: 1_100)
        XCTAssertEqual(try alerts([lock(false, 2_000)], at: 2_000 + 3_600), [], "old unlock, caught up at launch")

        try store.record([lock(true, 5_000), sensor(.started, screenSharing, 5_100), lock(false, 5_500)], lastProcessed: nil)
        let off = try AlertPlanner(store: store, settings: AlertSettings(sensors: .everyUse)) { _, _ in true }
            .alerts(for: [lock(false, 5_500)], now: base.addingTimeInterval(5_501))
        XCTAssertEqual(off, [], "setting off")
    }
}

final class CSVExportTests: XCTestCase {
    func testQuotingAndFormulaGuard() {
        XCTAssertEqual(CSV.field("Teams"), "Teams")
        XCTAssertEqual(CSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.field("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(CSV.field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CSV.field("+1"), "'+1")
        XCTAssertEqual(CSV.field("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(CSV.document(header: ["a", "b"], rows: [["1", "2"]]), "a,b\r\n1,2\r\n")
    }

    func testSessions() {
        let start = Date(timeIntervalSince1970: 1_791_500_000)   // 2026-10-09 00:53:20 +02:00
        let sessions = [
            SensorSession(id: 1, sensor: .microphone, app: "us.zoom.xos", startedAt: start, endedAt: start.addingTimeInterval(90.4)),
            SensorSession(id: 2, sensor: .camera, app: "com.example.Spy", startedAt: start, endedAt: nil),
        ]
        let locks = ScreenLockSpans([DateInterval(start: start.addingTimeInterval(60), duration: 600)])
        let csv = CSVExport.sessions(sessions, locks: locks, now: start.addingTimeInterval(120),
                                     timeZone: TimeZone(identifier: "Europe/Warsaw")!) { $0 == "us.zoom.xos" ? "zoom.us" : $0 }
        XCTAssertEqual(csv.components(separatedBy: "\r\n"), [
            "app,identifier,sensor,started,ended,duration_s,while_locked_s",
            "zoom.us,us.zoom.xos,Microphone,2026-10-09T00:53:20+02:00,2026-10-09T00:54:50+02:00,90,30",
            "com.example.Spy,com.example.Spy,Camera,2026-10-09T00:53:20+02:00,,120,60",
            "",
        ])
    }

    func testPermissions() {
        let seen = Date(timeIntervalSince1970: 1_791_500_000)
        let row = TCCAggregate(day: "2026-10-09", service: "kTCCServiceSystemPolicyDesktopFolder", app: "com.example.Spy",
                               accessor: "", binaryPath: "/Applications/Spy, Inc.app/Contents/MacOS/Spy", authValue: 0,
                               preflight: false, count: 3, firstSeen: seen, lastSeen: seen)
        let csv = CSVExport.permissions([row], timeZone: TimeZone(identifier: "UTC")!) { _, _ in "Spy" }
        XCTAssertEqual(csv.components(separatedBy: "\r\n")[1],
                       "2026-10-09,Spy,com.example.Spy,,\"/Applications/Spy, Inc.app/Contents/MacOS/Spy\",Desktop Folder,"
                       + "kTCCServiceSystemPolicyDesktopFolder,Denied,no,3,2026-10-08T22:53:20Z,2026-10-08T22:53:20Z")
    }
}
