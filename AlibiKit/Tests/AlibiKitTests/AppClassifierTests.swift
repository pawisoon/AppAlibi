import XCTest
@testable import AlibiKit

final class AppClassifierTests: XCTestCase {
    func testThirdPartyAppsAndTheirHelpers() {
        XCTAssertEqual(AppClassifier.kind(identifier: "com.microsoft.teams2"), .app)
        XCTAssertEqual(AppClassifier.kind(
            identifier: "com.macpaw.CleanMyMac5.HealthMonitor",
            binaryPath: "/Applications/CleanMyMac_5.app/Contents/Library/LoginItems/CleanMyMac_5_HealthMonitor.app/Contents/MacOS/CleanMyMac_5_HealthMonitor"), .app)
    }

    func testAppleAppsInApplicationsFoldersAreApps() {
        XCTAssertEqual(AppClassifier.kind(identifier: "com.apple.FaceTime", bundlePath: "/System/Applications/FaceTime.app"), .app)
        XCTAssertEqual(AppClassifier.kind(identifier: "com.apple.git",
                                          binaryPath: "/Applications/Xcode-27.0.0.app/Contents/Developer/usr/bin/git"), .app)
    }

    func testSystemServices() {
        XCTAssertEqual(AppClassifier.kind(identifier: "System Services"), .system)
        XCTAssertEqual(AppClassifier.kind(identifier: "com.apple.systemuiserver",
                                          bundlePath: "/System/Library/CoreServices/SystemUIServer.app"), .system)
        XCTAssertEqual(AppClassifier.kind(identifier: "com.apple.sandboxd", binaryPath: "/usr/libexec/sandboxd"), .system)
        XCTAssertEqual(AppClassifier.kind(identifier: "com.apple.remindd"), .system, "unresolved Apple identifiers default to system")
    }

    func testUnknownThirdPartyDefaultsToApp() {
        XCTAssertEqual(AppClassifier.kind(identifier: "com.example.agent", binaryPath: "/Library/PrivilegedHelperTools/com.example.agent"), .app)
    }
}
