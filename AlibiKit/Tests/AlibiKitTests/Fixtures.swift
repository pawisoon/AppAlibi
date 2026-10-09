import Foundation
@testable import AlibiKit

/// Real lines captured from macOS 27.0.1 (26A434) on 2026-10-09.
enum Fixtures {
    static let controlCenterNDJSON = #"{"timezoneName":"","messageType":"Default","eventType":"logEvent","source":null,"formatString":"Recent activity attributions changed to %{public}s","userID":501,"subsystem":"com.apple.controlcenter","category":"sensor-indicators","threadID":4180342,"processImagePath":"\/System\/Library\/CoreServices\/ControlCenter.app\/Contents\/MacOS\/ControlCenter","timestamp":"2026-10-08 00:11:56.880495+0200","machTimestamp":9549646048899,"eventMessage":"Active activity attributions changed to [\"cam:com.microsoft.teams2\", \"mic:com.microsoft.teams2\"]","traceID":36386481929060356,"processID":940,"senderProgramCounter":1124492,"parentActivityIdentifier":0}"#

    static let streamHeader = #"Filtering the log data using "process == "tccd"""#
    static let showSummary = #"{"count":183,"finished":1}"#

    static let tccContext = "AUTHREQ_CTX: msgID=47863.1, function=TCCAccessRequest, service=kTCCServiceAddressBook, preflight=yes, query=1, client_dict=(null), daemon_dict=<private>"
    static let tccAttribution = "AUTHREQ_ATTRIBUTION: msgID=47863.1, attribution={responsible={TCCDProcess: identifier=com.apple.dt.xcode_select.tool-shim-public, pid=88923, auid=501, euid=501, responsible_path=/usr/bin/git, binary_path=/Applications/Xcode-27.0.0.app/Contents/Developer/usr/bin/git}, accessing={TCCDProcess: identifier=com.apple.git, pid=88923, auid=501, euid=501, binary_path=/Applications/Xcode-27.0.0.app/Contents/Developer/usr/bin/git}, requesting={TCCDProcess: identifier=com.apple.sandboxd, pid=71374, auid=0, euid=0, binary_path=/usr/libexec/sandboxd}, },"
    static let tccResult = "AUTHREQ_RESULT: msgID=47863.1, authValue=2, authReason=11, authVersion=1, desired_auth=0, error=(null),"

    static let tccAttributionResponsibleOnly = "AUTHREQ_ATTRIBUTION: msgID=51452.1, attribution={responsible={TCCDProcess: identifier=com.macpaw.CleanMyMac5.HealthMonitor, pid=1593, auid=501, euid=501, responsible_path=/Applications/CleanMyMac_5.app/Contents/Library/LoginItems/CleanMyMac_5_HealthMonitor.app/Contents/MacOS/CleanMyMac_5_HealthMonitor, binary_path=/Applications/CleanMyMac_5.app/Contents/Library/LoginItems/CleanMyMac_5_HealthMonitor.app/Contents/MacOS/CleanMyMac_5_HealthMonitor}, requesting={TCCDProcess: identifier=com.macpaw.CleanMyMac5.BluetoothDevicesXPCService, pid=51452, auid=501, euid=501, binary_path=/Applications/CleanMyMac_5.app/Contents/Library/LoginItems/CleanMyMac_5_HealthMonitor.app/Contents/XPCServices/com.macpaw.CleanMyMac5.BluetoothDevicesXPCService.xpc/Contents/MacOS/com.macpaw.CleanMyMac5.BluetoothDevicesXPCService}, },"

    static let tccAttributionRequestingOnly = "AUTHREQ_ATTRIBUTION: msgID=45510.1, attribution={requesting={TCCDProcess: identifier=com.apple.AddressBookSourceSync, pid=45510, auid=501, euid=501, binary_path=/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/AddressBookSourceSync.app/Contents/MacOS/AddressBookSourceSync}, },"

    static func entry(_ message: String, at seconds: TimeInterval = 0, pid: Int = 579) -> LogEntry {
        LogEntry(timestamp: Date(timeIntervalSince1970: 1_791_500_000 + seconds), eventMessage: message, processID: pid)
    }

    static func snapshot(_ items: [String]) -> String {
        let json = items.map { "\"\($0)\"" }.joined(separator: ", ")
        return "Active activity attributions changed to [\(json)]"
    }
}
