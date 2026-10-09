import XCTest
@testable import AlibiKit

final class LogEntryTests: XCTestCase {
    func testParsesRealNDJSONLine() throws {
        let entry = try XCTUnwrap(LogEntry.parse(Fixtures.controlCenterNDJSON))
        XCTAssertEqual(entry.processID, 940)
        XCTAssertEqual(entry.subsystem, "com.apple.controlcenter")
        XCTAssertEqual(entry.category, "sensor-indicators")
        XCTAssertTrue(entry.eventMessage.hasPrefix("Active activity attributions changed to"))
    }

    func testSkipsStreamHeaderAndShowSummary() {
        XCTAssertNil(LogEntry.parse(Fixtures.streamHeader))
        XCTAssertNil(LogEntry.parse(Fixtures.showSummary))
        XCTAssertNil(LogEntry.parse(""))
        XCTAssertNil(LogEntry.parse("{not json"))
    }

    func testTimestampKeepsMicrosecondsAndZone() throws {
        let date = try XCTUnwrap(LogTimestamp.parse("2026-10-08 00:11:56.880495+0200"))
        // 2026-10-07 22:11:56.880495 UTC
        XCTAssertEqual(date.timeIntervalSince1970, 1_791_411_116.880495, accuracy: 0.000_01)
        let negative = try XCTUnwrap(LogTimestamp.parse("2026-10-07 18:11:56.500000-0400"))
        XCTAssertEqual(negative.timeIntervalSince1970, 1_791_411_116.5, accuracy: 0.000_01)
    }

    func testStartArgumentRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_791_411_116)
        let argument = LogTimestamp.argument(for: date)
        XCTAssertEqual(LogTimestamp.parse(argument), date)
    }
}

final class ControlCenterParserTests: XCTestCase {
    func testParsesCameraAndMicrophone() throws {
        let entry = try XCTUnwrap(LogEntry.parse(Fixtures.controlCenterNDJSON))
        let snapshot = try XCTUnwrap(ControlCenterParser.snapshot(from: entry.eventMessage))
        XCTAssertEqual(snapshot, [
            Attribution(sensor: .camera, app: "com.microsoft.teams2"),
            Attribution(sensor: .microphone, app: "com.microsoft.teams2"),
        ])
    }

    func testEmptySnapshot() {
        XCTAssertEqual(ControlCenterParser.snapshot(from: "Active activity attributions changed to []"), [])
    }

    func testNonBundleNameAndUnknownTagAreKept() throws {
        let snapshot = try XCTUnwrap(ControlCenterParser.snapshot(from: Fixtures.snapshot(["loc:System Services", "xyz:com.example.app"])))
        XCTAssertTrue(snapshot.contains(Attribution(sensor: .location, app: "System Services")))
        XCTAssertTrue(snapshot.contains(Attribution(sensor: Sensor(rawValue: "xyz"), app: "com.example.app")))
    }

    func testDuplicatesCollapse() throws {
        let snapshot = try XCTUnwrap(ControlCenterParser.snapshot(from: Fixtures.snapshot(["mic:com.microsoft.teams2", "mic:com.microsoft.teams2"])))
        XCTAssertEqual(snapshot.count, 1)
    }

    func testIgnoresOtherMessages() {
        XCTAssertNil(ControlCenterParser.snapshot(from: "Recent activity attributions changed to [\"cam:com.apple.FaceTime\"]"))
        XCTAssertNil(ControlCenterParser.snapshot(from: "Sorted active attributions from SystemStatus update: []"))
        XCTAssertNil(ControlCenterParser.snapshot(from: "Active activity attributions changed to garbage"))
    }
}
