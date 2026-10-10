import XCTest
@testable import AlibiKit

final class SessionTrackerTests: XCTestCase {
    let cam = Attribution(sensor: .camera, app: "com.microsoft.teams2")
    let mic = Attribution(sensor: .microphone, app: "com.microsoft.teams2")
    let t0 = Date(timeIntervalSince1970: 100)
    let t1 = Date(timeIntervalSince1970: 200)

    func testStartsAndEnds() {
        var tracker = SessionTracker()
        XCTAssertEqual(tracker.apply([cam, mic], at: t0), [
            SensorEvent(kind: .started, attribution: cam, date: t0),
            SensorEvent(kind: .started, attribution: mic, date: t0),
        ])
        XCTAssertEqual(tracker.apply([mic], at: t1), [
            SensorEvent(kind: .ended, attribution: cam, date: t1),
        ])
        XCTAssertEqual(tracker.active, [mic])
    }

    func testRepeatedSnapshotIsQuiet() {
        var tracker = SessionTracker(active: [cam])
        XCTAssertEqual(tracker.apply([cam], at: t0), [])
    }

    func testRestoredStateEndsOnNextSnapshot() {
        var tracker = SessionTracker(active: [cam])
        XCTAssertEqual(tracker.apply([], at: t1), [SensorEvent(kind: .ended, attribution: cam, date: t1)])
    }
}

final class TCCCorrelatorTests: XCTestCase {
    func testJoinsThreeLinesInOrder() throws {
        var correlator = TCCCorrelator()
        XCTAssertEqual(correlator.consume(Fixtures.entry(Fixtures.tccContext)), [])
        XCTAssertEqual(correlator.consume(Fixtures.entry(Fixtures.tccAttribution)), [])
        let events = correlator.consume(Fixtures.entry(Fixtures.tccResult, at: 0.01))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.service, "kTCCServiceAddressBook")
        XCTAssertTrue(event.preflight)
        XCTAssertEqual(event.authValue, 2)
        XCTAssertEqual(event.app, "com.apple.dt.xcode_select.tool-shim-public")
        XCTAssertEqual(event.accessor, "com.apple.git")
        XCTAssertEqual(event.accessing?.pid, 88923)
        XCTAssertEqual(event.binaryPath, "/Applications/Xcode-27.0.0.app/Contents/Developer/usr/bin/git")
        XCTAssertEqual(correlator.pendingCount, 0)
    }

    func testJoinsOutOfOrder() {
        var correlator = TCCCorrelator()
        _ = correlator.consume(Fixtures.entry(Fixtures.tccResult))
        _ = correlator.consume(Fixtures.entry(Fixtures.tccAttribution))
        XCTAssertEqual(correlator.consume(Fixtures.entry(Fixtures.tccContext)).count, 1)
    }

    func testSameMsgIDInDifferentTccdIsSeparate() {
        var correlator = TCCCorrelator()
        _ = correlator.consume(Fixtures.entry(Fixtures.tccContext, pid: 245))
        _ = correlator.consume(Fixtures.entry(Fixtures.tccAttribution, pid: 579))
        XCTAssertEqual(correlator.consume(Fixtures.entry(Fixtures.tccResult, pid: 579)), [])
        XCTAssertEqual(correlator.pendingCount, 2)
    }

    func testResponsibleOnlyAttribution() throws {
        let process = try XCTUnwrap(TCCCorrelator.process(role: "responsible", in: Fixtures.tccAttributionResponsibleOnly))
        XCTAssertEqual(process.identifier, "com.macpaw.CleanMyMac5.HealthMonitor")
        XCTAssertEqual(process.pid, 1593)
        XCTAssertNil(TCCCorrelator.process(role: "accessing", in: Fixtures.tccAttributionResponsibleOnly))
    }

    func testRequestingOnlyBlamesTheRequester() throws {
        var correlator = TCCCorrelator()
        _ = correlator.consume(Fixtures.entry("AUTHREQ_CTX: msgID=45510.1, function=TCCAccessRequest, service=kTCCServiceAddressBook, preflight=no, query=1"))
        _ = correlator.consume(Fixtures.entry(Fixtures.tccAttributionRequestingOnly))
        let event = try XCTUnwrap(correlator.consume(Fixtures.entry("AUTHREQ_RESULT: msgID=45510.1, authValue=2, authReason=4,")).first)
        XCTAssertEqual(event.app, "com.apple.AddressBookSourceSync")
        XCTAssertEqual(event.accessor, "")
        XCTAssertTrue(event.binaryPath.hasSuffix("/AddressBookSourceSync"))
    }

    func testFieldMatchesWholeKeysOnly() {
        XCTAssertEqual(TCCCorrelator.field("pid", in: "{identifier=x, euid=501, pid=42, auid=1}"), "42")
        XCTAssertEqual(TCCCorrelator.field("auid", in: "{identifier=x, pid=42, auid=1}"), "1")
    }

    func testIncompleteCheckWithoutAttributionIsFlushedAfterTimeout() throws {
        var correlator = TCCCorrelator()
        _ = correlator.consume(Fixtures.entry(Fixtures.tccContext, at: 0))
        _ = correlator.consume(Fixtures.entry(Fixtures.tccResult, at: 0))
        let flushed = correlator.consume(Fixtures.entry("AUTHREQ_CTX: msgID=9.9, service=kTCCServiceCamera, preflight=no", at: 120))
        let event = try XCTUnwrap(flushed.first)
        XCTAssertEqual(event.service, "kTCCServiceAddressBook")
        XCTAssertEqual(event.app, "unknown")
    }

    func testServiceNames() {
        XCTAssertEqual(TCCService.displayName(for: "kTCCServiceSystemPolicyAllFiles"), "Full Disk Access")
        XCTAssertEqual(TCCService.displayName(for: "kTCCServiceSomethingNew"), "SomethingNew")
        // Seen on macOS 27.0.1 without a name before.
        XCTAssertEqual(TCCService.displayName(for: "kTCCServiceUbiquity"), "iCloud Drive")
        XCTAssertEqual(TCCService.displayName(for: "kTCCServiceWillow"), "Home")
        XCTAssertEqual(TCCService.displayName(for: "kTCCServiceVoiceBanking"), "Personal Voice")
        XCTAssertEqual(TCCService.displayName(for: "kTCCServiceWebBrowserPublicKeyCredential"), "Passkeys for Web Browsers")
        XCTAssertEqual(TCCService.displayName(for: "kTCCServicePhotosAdd"), "Add to Photos")
        XCTAssertTrue(TCCService.isFileAccess("kTCCServiceSystemPolicyDesktopFolder"))
        XCTAssertEqual(TCCService.resultName(for: 0), "Denied")
    }
}

final class EventProcessorTests: XCTestCase {
    func testRoutesBothSources() {
        var processor = EventProcessor()
        let started = processor.process(Fixtures.entry(Fixtures.snapshot(["scr:com.apple.systemuiserver"]), pid: 940))
        XCTAssertEqual(started.count, 1)
        _ = processor.process(Fixtures.entry(Fixtures.tccContext))
        _ = processor.process(Fixtures.entry(Fixtures.tccAttribution))
        let tcc = processor.process(Fixtures.entry(Fixtures.tccResult))
        guard case .tcc = tcc.first else { return XCTFail("expected a tcc event") }
        XCTAssertEqual(processor.process(Fixtures.entry("unrelated message")), [])
    }
}
