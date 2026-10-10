import XCTest
@testable import AlibiKit

final class AdminRightTests: XCTestCase {
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
    let installer = "/Applications/Sketchy Installer.app/Contents/MacOS/Sketchy Installer"
    let isApp: (String, String?) -> Bool = { _, path in path?.contains("/Applications/") == true }

    private func grant(_ seconds: TimeInterval, right: String = "system.privilege.admin", app: String? = nil) -> CollectedEvent {
        let path = app ?? installer
        return .adminRight(AdminRightEvent(date: base.addingTimeInterval(seconds), right: right, client: path, creator: path))
    }

    // MARK: Parsing

    func testParsesRealLines() throws {
        let mdm = try XCTUnwrap(AdminRightParser.event(from: Fixtures.entry(Fixtures.adminRightMDM)))
        XCTAssertEqual(mdm.right, "system.privilege.admin")
        XCTAssertEqual(mdm.client, "/usr/libexec/mdmclient")
        XCTAssertEqual(mdm.app, "/usr/libexec/mdmclient")

        let update = try XCTUnwrap(AdminRightParser.event(from: Fixtures.entry(Fixtures.adminRightSoftwareUpdate)))
        XCTAssertEqual(update.right, "com.apple.SoftwareUpdate.modify-settings")
        XCTAssertEqual(update.client, "/System/Library/CoreServices/Software Update.app/Contents/Resources/softwareupdated",
                       "a path with a space")
        XCTAssertEqual(update.app, "/System/Library/PrivateFrameworks/SoftwareUpdate.framework/Versions/A/Resources/SoftwareUpdateNotificationManager.app")
    }

    func testIgnoresLoginRightsAndOtherLines() {
        XCTAssertNil(AdminRightParser.event(from: Fixtures.entry(Fixtures.adminRightScreensaver)), "every password unlock")
        XCTAssertNil(AdminRightParser.event(from: Fixtures.entry(Fixtures.adminRightDenied)))
        XCTAssertNil(AdminRightParser.event(from: Fixtures.entry(Fixtures.tccResult)))
    }

    func testProcessorEmitsGrants() {
        var processor = EventProcessor()
        let entry = Fixtures.entry(Fixtures.adminRightMDM, at: 5)
        XCTAssertEqual(processor.process(entry), [.adminRight(AdminRightEvent(
            date: entry.timestamp, right: "system.privilege.admin",
            client: "/usr/libexec/mdmclient", creator: "/usr/libexec/mdmclient"))])
    }

    func testRightsOpenToEveryoneAreSkipped() {
        // Read from this Mac's authorization database: `system.burn` is `allow`, admin needs a password.
        XCTAssertTrue(AdminRight.isOpenToEveryone("system.burn"))
        XCTAssertFalse(AdminRight.isOpenToEveryone("system.privilege.admin"))
        XCTAssertFalse(AdminRight.isOpenToEveryone("com.example.no-such-right"))

        var processor = EventProcessor()
        let burn = Fixtures.adminRightMDM.replacingOccurrences(of: "system.privilege.admin", with: "system.burn")
        XCTAssertEqual(processor.process(Fixtures.entry(burn)), [])
        processor.isOpenRight = { _ in false }
        XCTAssertEqual(processor.process(Fixtures.entry(burn)).count, 1)
    }

    func testDisplayNames() {
        XCTAssertEqual(AdminRight.displayName(for: "system.privilege.admin"), "Administrator access")
        XCTAssertEqual(AdminRight.displayName(for: "system.install.apple-software"), "Install Apple software")
        XCTAssertEqual(AdminRight.displayName(for: "system.install.apple-software.standard-user"),
                       "Install Apple software (standard user)")
        XCTAssertEqual(AdminRight.displayName(for: "system.install.software.iap"), "Install software")
        XCTAssertEqual(AdminRight.displayName(for: "com.example.custom-right"), "com.example.custom-right")
    }

    // MARK: Store

    func testStoresDailyAggregates() throws {
        try store.record([grant(0), grant(60), grant(120, right: "system.install.software")], lastProcessed: nil)
        let rows = try store.adminRights()
        XCTAssertEqual(rows.count, 2)
        let admin = try XCTUnwrap(rows.first { $0.right == "system.privilege.admin" })
        XCTAssertEqual(admin.count, 2)
        XCTAssertEqual(admin.firstSeen, base)
        XCTAssertEqual(admin.lastSeen, base.addingTimeInterval(60))
        XCTAssertEqual(try store.adminRightApps(), [installer])
        XCTAssertEqual(try store.adminRights(AdminRightQuery(appContains: "install")).count, 2, "matches the right too")
        XCTAssertEqual(try store.adminRights(AdminRightQuery(apps: ["/usr/libexec/mdmclient"])).count, 0)
    }

    func testRetentionAndDeleteAll() throws {
        try store.record([grant(0), grant(5 * 86_400)], lastProcessed: nil)
        try store.deleteOlderThan(base.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(try store.adminRights().map(\.lastSeen), [base.addingTimeInterval(5 * 86_400)])
        try store.deleteAll()
        XCTAssertEqual(try store.adminRights(), [])
    }

    func testHistoryImportRunsOncePerSource() throws {
        try store.markHistoryImported(.screenLocks)
        XCTAssertTrue(try store.needsHistoryImport(.adminRights), "a database from before admin rights")
        try store.markHistoryImported(.adminRights)
        XCTAssertFalse(try store.needsHistoryImport(.adminRights))
    }

    // MARK: Alerts

    private func alerts(_ events: [CollectedEvent], adminRights: Bool = true, at seconds: TimeInterval) throws -> [AccessAlert] {
        try store.record(events, lastProcessed: nil)
        return try AlertPlanner(store: store, settings: AlertSettings(adminRights: adminRights), isApp: isApp)
            .alerts(for: events, now: base.addingTimeInterval(seconds))
    }

    func testOneAlertPerAppWithItsRights() throws {
        let events = [grant(0), grant(1, right: "system.install.software"), grant(2)]
        XCTAssertEqual(try alerts(events, at: 10), [
            .adminRights(app: installer, rights: ["system.privilege.admin", "system.install.software"], date: base),
        ])
    }

    func testSystemServicesCatchUpAndDisabledAreQuiet() throws {
        XCTAssertEqual(try alerts([grant(0, app: "/usr/libexec/mdmclient")], at: 10), [])
        XCTAssertEqual(try alerts([grant(0)], at: 600), [], "catching up on old log lines")
        XCTAssertEqual(try alerts([grant(0)], adminRights: false, at: 10), [])
    }

    // MARK: Export

    func testCSV() {
        let row = AdminRightAggregate(day: "2026-10-09", right: "system.privilege.admin", app: installer, client: installer,
                                      count: 2, firstSeen: base, lastSeen: base)
        let csv = CSVExport.adminRights([row], timeZone: TimeZone(identifier: "UTC")!) { _ in "Sketchy Installer" }
        XCTAssertEqual(csv.components(separatedBy: "\r\n"), [
            "day,app,app_path,client_path,admin_right,right,count,first_seen,last_seen",
            "2026-10-09,Sketchy Installer,\(installer),\(installer),Administrator access,system.privilege.admin,2,"
                + "2026-10-08T22:53:20Z,2026-10-08T22:53:20Z",
            "",
        ])
    }
}
