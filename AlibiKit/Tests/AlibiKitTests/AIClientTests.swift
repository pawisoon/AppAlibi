import XCTest
@testable import AlibiKit

final class AIClientTests: XCTestCase {
    var url: URL!
    var store: EventStore!
    let catalog = AIClientCatalog.builtIn
    let base = Date(timeIntervalSince1970: 1_791_500_000)
    let anyApp: (String, String?) -> Bool = { id, _ in !id.hasPrefix("com.apple.") }

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

    /// A whole tccd check around a real attribution line.
    private func check(_ attribution: String, service: String, authValue: Int = 2, preflight: Bool = false,
                       at seconds: TimeInterval = 0) -> TCCAccessEvent {
        let msgID = TCCCorrelator.field("msgID", in: attribution)!
        var correlator = TCCCorrelator()
        _ = correlator.consume(Fixtures.entry(
            "AUTHREQ_CTX: msgID=\(msgID), function=TCCAccessRequest, service=\(service), preflight=\(preflight ? "yes" : "no"), query=1, client_dict=(null), daemon_dict=<private>",
            at: seconds))
        _ = correlator.consume(Fixtures.entry(attribution, at: seconds))
        return correlator.consume(Fixtures.entry(
            "AUTHREQ_RESULT: msgID=\(msgID), authValue=\(authValue), authReason=2, authVersion=1, desired_auth=0, error=(null),",
            at: seconds)).first!
    }

    private func spy(_ service: String, authValue: Int = 2, preflight: Bool = false, at seconds: TimeInterval) -> CollectedEvent {
        .tcc(TCCAccessEvent(date: base.addingTimeInterval(seconds), service: service, preflight: preflight, authValue: authValue,
                            responsible: TCCProcess(identifier: "com.example.Spy", pid: 1, binaryPath: "/Applications/Spy.app/Contents/MacOS/Spy"),
                            accessing: nil))
    }

    // MARK: Matching

    func testRealLinesMatchTheirClient() {
        XCTAssertEqual(catalog.client(for: check(Fixtures.claudeCodeResponsible, service: "kTCCServiceSystemPolicyDocumentsFolder"))?.id, "claude-code")
        XCTAssertEqual(catalog.client(for: check(Fixtures.claudeCodeAccessing, service: "kTCCServiceSystemPolicyAllFiles"))?.id, "claude-code")
        XCTAssertEqual(catalog.client(for: check(Fixtures.claudeIOSSim, service: "kTCCServiceListenEvent"))?.id, "claude")
        XCTAssertEqual(catalog.client(for: check(Fixtures.claudeDesktopHelper, service: "kTCCServiceScreenCapture"))?.id, "claude")
        XCTAssertNil(catalog.client(for: check(Fixtures.appInClaudeWorktree, service: "kTCCServiceSystemPolicyAppBundles")),
                     "a .claude/worktrees folder is not Claude")
    }

    func testCLIsMatchByPathOrBinaryName() {
        XCTAssertEqual(catalog.client(identifier: "2.1.265", path: "/Users/me/.local/share/claude/versions/2.1.265")?.id, "claude-code")
        XCTAssertEqual(catalog.client(identifier: "codex", path: "/usr/local/Cellar/codex/0.46.0/bin/codex")?.id, "openai")
        XCTAssertEqual(catalog.client(identifier: "kimi", path: "/Users/me/.kimi-code/bin/kimi")?.id, "kimi")
        XCTAssertEqual(catalog.client(identifier: "ai.perplexity.mac")?.id, "perplexity")
        XCTAssertEqual(catalog.client(identifier: "ai.perplexity.comet")?.id, "perplexity")
        XCTAssertNil(catalog.client(identifier: "node", path: "/opt/homebrew/bin/node"))
        XCTAssertNil(catalog.client(identifier: "com.openaitools.thing"), "a prefix ends at the dot")
    }

    func testCustomClientComesFirst() {
        let custom = AIClient.custom(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app")
        let mine = catalog.adding([custom])
        XCTAssertEqual(mine.client(identifier: "com.raycast.macos")?.id, "custom:com.raycast.macos")
        XCTAssertNil(catalog.client(identifier: "com.raycast.macos"))
        let tool = AIClient.custom(name: "agent", bundleID: nil, path: "/Users/me/bin/agent")
        XCTAssertEqual(catalog.adding([tool]).client(identifier: "agent", path: "/Users/me/bin/agent")?.id, "custom:/Users/me/bin/agent")
    }

    // MARK: Storage

    func testHistoryBeforeTrackingIsCopiedOnceAndApproximate() throws {
        let documents = "kTCCServiceSystemPolicyDocumentsFolder"
        try store.record([.tcc(check(Fixtures.claudeCodeResponsible, service: documents)),
                          .tcc(check(Fixtures.claudeCodeResponsible, service: documents, at: 60))], lastProcessed: nil)
        XCTAssertEqual(try store.aiAccess(), [], "nothing tracked before the clients are set")

        try store.setAIClients(catalog)
        let copied = try store.aiAccess()
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied.first?.count, 2)
        XCTAssertEqual(copied.first?.approximate, true)
        XCTAssertEqual(copied.first?.app, "com.anthropic.claude-code")
        XCTAssertEqual(copied.first?.accessor, "a.out")

        try store.setAIClients(catalog)
        try store.record([.tcc(check(Fixtures.claudeCodeResponsible, service: documents, at: 120))], lastProcessed: nil)
        let rows = try store.aiAccess()
        XCTAssertEqual(rows.map(\.count).reduce(0, +), 3, "copied once, then counted as it happens")
        XCTAssertEqual(rows.filter { !$0.approximate }.count, 1)

        try store.setAIClients(AIClientCatalog(catalog.clients.filter { $0.id != "claude-code" }))
        XCTAssertEqual(try store.aiAccess(), [], "a client taken out loses its rows")
    }

    func testAdminGrantByAnAIClient() throws {
        try store.setAIClients(catalog.adding([AIClient.custom(name: "Helper", bundleID: nil, path: "/Applications/Helper.app")]))
        let event = AdminRightEvent(date: base, right: "system.privilege.admin",
                                    client: "/Applications/Helper.app/Contents/MacOS/Helper", creator: "/Applications/Helper.app")
        try store.record([.adminRight(event)], lastProcessed: nil)
        let rows = try store.aiAccess(AIAccessQuery(kinds: [.admin]))
        XCTAssertEqual(rows.map(\.client), ["custom:/Applications/Helper.app"])
        XCTAssertEqual(try store.aiAdminClients().keys.sorted(), ["custom:/Applications/Helper.app"])
    }

    func testRetentionDeletesAIRows() throws {
        try store.setAIClients(catalog)
        try store.record([.tcc(check(Fixtures.claudeCodeAccessing, service: "kTCCServiceSystemPolicyAllFiles", authValue: 0, preflight: true))],
                         lastProcessed: nil)
        XCTAssertEqual(try store.aiAccess().count, 1)
        try store.deleteOlderThan(base.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(try store.aiAccess(), [])
    }

    // MARK: Timeline

    func testScreenRecordingWithAControlCheckIsProbablyComputerUse() throws {
        try store.setAIClients(catalog)
        var processor = EventProcessor()
        var events = processor.process(Fixtures.entry(Fixtures.claudeScreenSnapshot, at: 0))
        events += processor.process(Fixtures.entry(Fixtures.snapshot([]), at: 300))
        events.append(.tcc(check(Fixtures.claudeDesktopHelper, service: "kTCCServiceAccessibility", preflight: true, at: 10)))
        try store.record(events, lastProcessed: nil)

        let timeline = try AITimeline.build(store: store, catalog: catalog,
                                            query: AITimelineQuery(includePreflight: true), now: base.addingTimeInterval(400))
        let screen = try XCTUnwrap(timeline.first { $0.kind == .sensor })
        XCTAssertEqual(screen.client, "claude")
        XCTAssertEqual(screen.sensor, .screen)
        XCTAssertEqual(screen.duration(), 300)
        XCTAssertTrue(screen.isProbablyComputerUse)
        let control = try XCTUnwrap(timeline.first { $0.kind == .permission })
        XCTAssertTrue(control.isFirstTime)
        XCTAssertEqual(control.what, "Can control mouse and keyboard")
        XCTAssertFalse(timeline.contains { $0.app == "com.microsoft.teams2" }, "Teams is not an AI client")

        let realOnly = try AITimeline.build(store: store, catalog: catalog, query: AITimelineQuery(), now: base.addingTimeInterval(400))
        XCTAssertEqual(realOnly.map(\.kind), [.sensor], "preflight checks hidden")
    }

    func testReportShowsNewAccessInThePeriod() throws {
        try store.setAIClients(catalog)
        try store.record([.tcc(check(Fixtures.claudeCodeAccessing, service: "kTCCServiceScreenCapture", at: 100)),
                          .tcc(check(Fixtures.claudeCodeAccessing, service: "kTCCServiceScreenCapture", at: 90_000))],
                         lastProcessed: nil)
        let first = try AIReport.build(store: store, catalog: catalog,
                                       interval: DateInterval(start: base, duration: 86_400), now: base.addingTimeInterval(200_000))
        XCTAssertEqual(first.clients.map(\.client), ["claude-code"])
        XCTAssertEqual(first.clients.first?.newAccess, ["kTCCServiceScreenCapture"])
        XCTAssertEqual(first.clients.first?.checks, 1)
        let second = try AIReport.build(store: store, catalog: catalog,
                                        interval: DateInterval(start: base.addingTimeInterval(86_400), duration: 86_400),
                                        now: base.addingTimeInterval(200_000))
        XCTAssertEqual(second.clients.first?.newAccess, [], "not new the next day")
    }

    // MARK: Alerts

    private func alerts(_ events: [CollectedEvent], _ settings: AlertSettings, at seconds: TimeInterval) throws -> [AccessAlert] {
        try store.record(events, lastProcessed: nil)
        return try AlertPlanner(store: store, settings: settings, isApp: anyApp).alerts(for: events, now: base.addingTimeInterval(seconds))
    }

    func testFirstControlGrantForAnAIClientAlertsOnce() throws {
        try store.setAIClients(catalog)
        let settings = AlertSettings(aiClients: true)
        let listen = { (seconds: TimeInterval) in
            CollectedEvent.tcc(self.check(Fixtures.claudeIOSSim, service: "kTCCServiceListenEvent", preflight: true, at: seconds))
        }
        let first = try alerts([listen(0), listen(1)], settings, at: 2)
        XCTAssertEqual(first.count, 1)
        guard case .aiFirstAccess(let client, _, _, let service, _) = first.first else { return XCTFail("expected an AI alert") }
        XCTAssertEqual(client, "claude")
        XCTAssertEqual(service, "kTCCServiceListenEvent")
        XCTAssertEqual(try alerts([listen(10)], settings, at: 11), [])
        let documents = CollectedEvent.tcc(check(Fixtures.claudeCodeResponsible, service: "kTCCServiceSystemPolicyDocumentsFolder", at: 20))
        XCTAssertEqual(try alerts([documents], settings, at: 21), [], "folders are not a control service")
    }

    func testFullDiskAccessAlertsOnFirstAllowedResult() throws {
        try store.setAIClients(catalog)
        let settings = AlertSettings(fullDiskAccess: true)
        let fda = EventStore.fullDiskAccessService
        XCTAssertEqual(try alerts([spy(fda, authValue: 0, preflight: true, at: 0)], settings, at: 1), [], "denied")
        let first = try alerts([spy(fda, preflight: true, at: 10)], settings, at: 11)
        XCTAssertEqual(first, [.fullDiskAccess(app: "com.example.Spy", binaryPath: "/Applications/Spy.app/Contents/MacOS/Spy",
                                               date: base.addingTimeInterval(10))])
        XCTAssertEqual(try alerts([spy(fda, at: 20)], settings, at: 21), [])
    }

    func testAIAdminGrantIsToldOnce() throws {
        let helper = AIClient.custom(name: "Helper", bundleID: nil, path: "/Applications/Helper.app")
        try store.setAIClients(catalog.adding([helper]))
        let event = CollectedEvent.adminRight(AdminRightEvent(date: base, right: "system.privilege.admin",
                                                              client: "/Applications/Helper.app", creator: "/Applications/Helper.app"))
        let result = try alerts([event], AlertSettings(adminRights: true, aiClients: true), at: 1)
        XCTAssertEqual(result, [.aiAdminRights(client: helper.id, app: "/Applications/Helper.app",
                                               rights: ["system.privilege.admin"], date: base)])
    }

    func testAIUseWhileLockedIsToldOnUnlock() throws {
        try store.setAIClients(catalog)
        var processor = EventProcessor()
        var events = [CollectedEvent.screenLock(ScreenLockEvent(locked: true, date: base))]
        events += processor.process(Fixtures.entry(Fixtures.claudeScreenSnapshot, at: 60))
        events += processor.process(Fixtures.entry(Fixtures.snapshot([]), at: 180))
        events.append(.tcc(check(Fixtures.claudeCodeAccessing, service: "kTCCServicePostEvent", at: 120)))
        try store.record(events, lastProcessed: nil)

        let unlock = CollectedEvent.screenLock(ScreenLockEvent(locked: false, date: base.addingTimeInterval(600)))
        let result = try alerts([unlock], AlertSettings(aiClients: true), at: 601)
        XCTAssertEqual(result, [.aiLockedUse(lock: DateInterval(start: base, end: base.addingTimeInterval(600)), clients: [
            AILockedUse(client: "claude-code", sensors: [], services: ["kTCCServicePostEvent"]),
            AILockedUse(client: "claude", sensors: [.screen], services: []),
        ])])
    }
}
