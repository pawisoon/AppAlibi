import XCTest
@testable import AlibiKit

final class LogRetentionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ plist: [String: Any], subsystem: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent(subsystem + ".plist"))
    }

    /// Applies changes the way the root script does.
    private func apply(_ changes: [LogRetention.FileChange]) throws {
        for change in changes {
            if let contents = change.contents {
                try contents.write(to: change.url)
            } else {
                try FileManager.default.removeItem(at: change.url)
            }
        }
    }

    private func plist(_ subsystem: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(subsystem + ".plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testEnableWritesATTLForEverySource() throws {
        XCTAssertFalse(LogRetention.isEnabled(in: directory))
        let changes = try LogRetention.changes(enable: true, in: directory)
        XCTAssertEqual(changes.count, LogRetention.sources.count)
        try apply(changes)
        XCTAssertTrue(LogRetention.isEnabled(in: directory))
        XCTAssertEqual(LogRetention.ttl(of: "sensor-indicators", in: try plist("com.apple.controlcenter")), LogRetention.days)
        XCTAssertEqual(try LogRetention.changes(enable: true, in: directory), [], "already on")
    }

    func testKeepsOtherSettingsInTheFile() throws {
        // What `log config --subsystem com.apple.controlcenter --category other --mode persist:info` leaves.
        try write(["other": ["Level": ["Persist": "Info"]],
                   "sensor-indicators": ["Level": ["Enable": "Info"]]], subsystem: "com.apple.controlcenter")
        try apply(try LogRetention.changes(enable: true, in: directory))
        var file = try plist("com.apple.controlcenter")
        XCTAssertEqual((file["other"] as? [String: Any])?["Level"] as? [String: String], ["Persist": "Info"])
        XCTAssertEqual(((file["sensor-indicators"] as? [String: Any])?["Level"] as? [String: String]), ["Enable": "Info"])

        try apply(try LogRetention.changes(enable: false, in: directory))
        file = try plist("com.apple.controlcenter")
        XCTAssertNil(LogRetention.ttl(of: "sensor-indicators", in: file))
        XCTAssertEqual(((file["sensor-indicators"] as? [String: Any])?["Level"] as? [String: String]), ["Enable": "Info"])
        XCTAssertNotNil(file["other"])
        XCTAssertFalse(LogRetention.isEnabled(in: directory))
    }

    func testDisableDeletesFilesItCreatedAlone() throws {
        try apply(try LogRetention.changes(enable: true, in: directory))
        let changes = try LogRetention.changes(enable: false, in: directory)
        XCTAssertEqual(changes.count, LogRetention.sources.count)
        XCTAssertTrue(changes.allSatisfy { $0.contents == nil })
        try apply(changes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testLeavesALongerTTLAlone() throws {
        try write(["access": ["TTL": ["Default": 30]]], subsystem: "com.apple.TCC")
        let enabling = try LogRetention.changes(enable: true, in: directory)
        XCTAssertFalse(enabling.contains { $0.url.lastPathComponent == "com.apple.TCC.plist" })
        try apply(enabling)
        XCTAssertTrue(LogRetention.isEnabled(in: directory))
        try apply(try LogRetention.changes(enable: false, in: directory))
        XCTAssertEqual(LogRetention.ttl(of: "access", in: try plist("com.apple.TCC")), 30, "set by someone else")
    }

    func testShorterTTLIsRaised() throws {
        try write(["authd": ["TTL": ["Default": 3, "Fault": 30]]], subsystem: "com.apple.Authorization")
        try apply(try LogRetention.changes(enable: true, in: directory))
        let ttl = (try plist("com.apple.Authorization")["authd"] as? [String: Any])?["TTL"] as? [String: Int]
        XCTAssertEqual(ttl, ["Default": LogRetention.days, "Fault": 30])
    }

    func testScriptQuotesPathsAndNotifiesLogd() {
        let change = LogRetention.FileChange(url: URL(fileURLWithPath: "/Library/Preferences/Logging/Subsystems/a.plist"), contents: Data())
        let removal = LogRetention.FileChange(url: URL(fileURLWithPath: "/Library/Preferences/Logging/Subsystems/b.plist"), contents: nil)
        let script = LogRetention.script(installing: [(change, URL(fileURLWithPath: "/tmp/it's here.plist")), (removal, nil)])
        XCTAssertEqual(script.components(separatedBy: "\n"), [
            "set -e",
            "/bin/mkdir -p '/Library/Preferences/Logging/Subsystems'",
            "/usr/bin/install -m 644 -o root -g wheel '/tmp/it'\\''s here.plist' '/Library/Preferences/Logging/Subsystems/a.plist'",
            "/bin/rm -f '/Library/Preferences/Logging/Subsystems/b.plist'",
            "/usr/bin/notifyutil -p com.apple.system.logging.prefschanged"
        ])
    }

    func testSourcesMatchThePredicates() {
        XCTAssertTrue(LogPredicates.controlCenter.contains(#"subsystem == "com.apple.controlcenter""#))
        XCTAssertTrue(LogPredicates.controlCenter.contains(#"category == "sensor-indicators""#))
    }
}
