import XCTest
@testable import AlibiKit

final class AppActivityTests: XCTestCase {
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

    let app = "com.example.Spy"
    let base: TimeInterval = 1_791_500_000

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: base + seconds) }

    private func check(_ seconds: TimeInterval, _ service: String, authValue: Int = 2,
                       preflight: Bool = false, app: String? = nil) -> CollectedEvent {
        .tcc(TCCAccessEvent(
            date: date(seconds), service: "kTCCService" + service, preflight: preflight, authValue: authValue,
            responsible: TCCProcess(identifier: app ?? self.app, pid: 1, binaryPath: "/Applications/Spy.app/Contents/MacOS/Spy"),
            accessing: nil))
    }

    private func sensor(_ kind: SensorEvent.Kind, _ sensor: Sensor, _ seconds: TimeInterval, app: String? = nil) -> CollectedEvent {
        .sensor(SensorEvent(kind: kind, attribution: Attribution(sensor: sensor, app: app ?? self.app), date: date(seconds)))
    }

    private func right(_ seconds: TimeInterval, creator: String) -> CollectedEvent {
        .adminRight(AdminRightEvent(date: date(seconds), right: "system.privilege.admin", client: creator, creator: creator))
    }

    func testTimelineMergesSourcesNewestFirst() throws {
        try store.record([
            sensor(.started, .camera, 0),
            sensor(.ended, .camera, 120),
            check(200, "SystemPolicyDocumentsFolder"),
            right(300, creator: "/Applications/Spy.app/Contents/Library/LaunchServices/com.example.Spy.helper"),
            sensor(.started, .microphone, 400, app: "com.other.App"),
            check(500, "SystemPolicyDesktopFolder", app: "com.other.App"),
            right(600, creator: "/Applications/SpyOther.app"),
        ], lastProcessed: nil)

        let activity = try store.appActivity(AppActivityQuery(identifier: app, paths: ["/Applications/Spy.app"]),
                                             now: date(1_000))
        XCTAssertEqual(activity.timeline.map(\.start), [date(300), date(200), date(0)])
        XCTAssertEqual(activity.adminGrants, 1, "a sibling bundle sharing the name prefix does not match")
        XCTAssertEqual(activity.sensorTime.map(\.sensor), [.camera])
        XCTAssertEqual(activity.sensorTime.first?.duration ?? 0, 120, accuracy: 0.001)
    }

    func testFoldersFoldDaysAndResults() throws {
        try store.record([
            check(0, "SystemPolicyDownloadsFolder", authValue: 0),
            check(10, "SystemPolicyDownloadsFolder"),
            check(86_400 * 2, "SystemPolicyDownloadsFolder"),
            check(20, "SystemPolicyDesktopFolder", preflight: true),
            check(30, "Camera"),
            check(40, "Ubiquity"),
        ], lastProcessed: nil)

        let activity = try store.appActivity(AppActivityQuery(identifier: app))
        XCTAssertEqual(activity.folders.map(\.service), ["kTCCServiceSystemPolicyDownloadsFolder", "kTCCServiceUbiquity"],
                       "preflight and non-folder checks are left out")
        let downloads = try XCTUnwrap(activity.folders.first)
        XCTAssertEqual(downloads.count, 3)
        XCTAssertEqual(downloads.denied, 1)
        XCTAssertEqual(downloads.allowed, 2)
        XCTAssertEqual(downloads.lastResult, 2)
        XCTAssertEqual(activity.permissionChecks, 5)
        XCTAssertEqual(activity.deniedChecks, 1)
    }

    func testRangeClipsSessionsAndDropsOldRows() throws {
        try store.record([
            sensor(.started, .screen, 0),
            sensor(.ended, .screen, 1_000),
            check(10, "SystemPolicyDocumentsFolder"),
        ], lastProcessed: nil)

        let activity = try store.appActivity(AppActivityQuery(identifier: app, since: date(600)), now: date(2_000))
        XCTAssertEqual(activity.sensorTime.first?.duration ?? 0, 400, accuracy: 0.001)
        XCTAssertTrue(activity.folders.isEmpty)
    }

    func testFolderURLs() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(ProtectedFolder.url(for: "kTCCServiceSystemPolicyDocumentsFolder", home: home)?.path, "/Users/test/Documents")
        XCTAssertEqual(ProtectedFolder.url(for: "kTCCServiceSystemPolicyRemovableVolumes", home: home)?.path, "/Volumes")
        XCTAssertEqual(ProtectedFolder.url(for: "kTCCServiceUbiquity", home: home)?.path,
                       "/Users/test/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertNil(ProtectedFolder.url(for: "kTCCServiceCamera", home: home))
        XCTAssertTrue(ProtectedFolder.isFolder("kTCCServiceUbiquity"))
        XCTAssertFalse(ProtectedFolder.isFolder("kTCCServiceCamera"))
    }
}
