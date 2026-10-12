import XCTest
@testable import AlibiKit

final class EventStoreTests: XCTestCase {
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

    let cam = Attribution(sensor: .camera, app: "com.apple.FaceTime")

    func testSessionLifecycleAndCheckpoint() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 1_090)
        try store.record([.sensor(SensorEvent(kind: .started, attribution: cam, date: t0))], lastProcessed: t0)
        XCTAssertEqual(try store.openAttributions(), [cam])
        XCTAssertEqual(try store.sessions().first?.isActive, true)

        try store.record([.sensor(SensorEvent(kind: .ended, attribution: cam, date: t1))], lastProcessed: t1)
        XCTAssertEqual(try store.openAttributions(), [])
        let session = try XCTUnwrap(try store.sessions().first)
        XCTAssertEqual(session.duration(), 90, accuracy: 0.001)
        XCTAssertEqual(try store.lastProcessed(), t1)
    }

    func testQuickRestartContinuesSession() throws {
        func record(_ kind: SensorEvent.Kind, _ seconds: TimeInterval) throws {
            let date = Date(timeIntervalSince1970: seconds)
            try store.record([.sensor(SensorEvent(kind: kind, attribution: cam, date: date))], lastProcessed: date)
        }
        try record(.started, 1_000)
        try record(.ended, 1_002)
        try record(.started, 1_004)   // 2s gap: same session
        try record(.ended, 1_600)
        try record(.started, 1_700)   // 100s gap: new session
        let sessions = try store.sessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.last?.duration(), 600)
        XCTAssertEqual(sessions.first?.isActive, true)
    }

    func testSessionFilters() throws {
        let mic = Attribution(sensor: .microphone, app: "com.microsoft.teams2")
        let now = Date(timeIntervalSince1970: 5_000)
        try store.record([
            .sensor(SensorEvent(kind: .started, attribution: cam, date: now)),
            .sensor(SensorEvent(kind: .started, attribution: mic, date: now)),
        ], lastProcessed: now)
        XCTAssertEqual(try store.sessions(SessionQuery(sensors: [.microphone])).map(\.app), ["com.microsoft.teams2"])
        XCTAssertEqual(try store.sessions(SessionQuery(appContains: "FaceTime")).count, 1)
        XCTAssertEqual(try store.sessions(SessionQuery(sensors: [])).count, 0)
        try store.record([.sensor(SensorEvent(kind: .ended, attribution: cam, date: now))], lastProcessed: now)
        XCTAssertEqual(try store.sessions(SessionQuery(onlyActive: true)).map(\.app), ["com.microsoft.teams2"])
    }

    func testTCCAggregatesByDay() throws {
        func event(_ seconds: TimeInterval, preflight: Bool = false, app: String = "com.example.Spy") -> CollectedEvent {
            .tcc(TCCAccessEvent(
                date: Date(timeIntervalSince1970: 1_791_500_000 + seconds),
                service: "kTCCServiceSystemPolicyDesktopFolder",
                preflight: preflight, authValue: 2,
                responsible: TCCProcess(identifier: app, pid: 1, binaryPath: "/Applications/Spy.app"),
                accessing: nil))
        }
        try store.record([event(0), event(10), event(20, preflight: true), event(30, app: "com.apple.mdworker")], lastProcessed: nil)

        let rows = try store.tccAggregates()
        XCTAssertEqual(rows.count, 1, "preflight and Apple rows are hidden by default")
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(rows.first?.serviceName, "Desktop Folder")
        XCTAssertEqual(try store.tccAggregates(TCCQuery(includePreflight: true, includeApple: true)).count, 3)
        XCTAssertNil(try store.lastProcessed())
    }

    func testFilterByAppIdentifiers() throws {
        let loc = Attribution(sensor: .location, app: "System Services")
        let now = Date(timeIntervalSince1970: 7_000)
        try store.record([
            .sensor(SensorEvent(kind: .started, attribution: cam, date: now)),
            .sensor(SensorEvent(kind: .started, attribution: loc, date: now)),
        ], lastProcessed: now)
        XCTAssertEqual(Set(try store.sessionApps()), ["com.apple.FaceTime", "System Services"])
        XCTAssertEqual(try store.sessions(SessionQuery(apps: ["System Services"])).map(\.app), ["System Services"])
        XCTAssertEqual(try store.sessions(SessionQuery(apps: [])).count, 0)
    }

    func testReopenKeepsData() throws {
        try store.record([.sensor(SensorEvent(kind: .started, attribution: cam, date: Date()))], lastProcessed: Date())
        store = nil
        let reopened = try EventStore(url: url)
        XCTAssertEqual(try reopened.openAttributions(), [cam])
    }

    func testReadsSeeEachCommittedBatch() throws {
        // Reads go through their own connection; each batch must be visible as soon as it is stored.
        XCTAssertEqual(try store.sessions().count, 0)
        try store.record([.sensor(SensorEvent(kind: .started, attribution: cam, date: Date()))], lastProcessed: Date())
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertEqual(try store.sessionApps(), [cam.app])
    }

    func testDeleteAll() throws {
        try store.record([.sensor(SensorEvent(kind: .started, attribution: cam, date: Date()))], lastProcessed: Date())
        try store.deleteAll()
        XCTAssertEqual(try store.sessions().count, 0)
        XCTAssertNotNil(try store.lastProcessed(), "checkpoint survives so deleted history is not re-imported")
    }
}
