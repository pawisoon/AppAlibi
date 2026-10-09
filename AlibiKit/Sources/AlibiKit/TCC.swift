import Foundation

public struct TCCProcess: Equatable, Sendable {
    public let identifier: String
    public let pid: Int
    public let binaryPath: String?

    public init(identifier: String, pid: Int, binaryPath: String?) {
        self.identifier = identifier
        self.pid = pid
        self.binaryPath = binaryPath
    }
}

/// One completed tccd permission check.
public struct TCCAccessEvent: Equatable, Sendable {
    public let date: Date
    public let service: String
    public let preflight: Bool
    public let authValue: Int
    public let responsible: TCCProcess?
    public let accessing: TCCProcess?
    /// The process that asked tccd. When it is the only role logged, it is checking its own access.
    public let requesting: TCCProcess?

    public init(date: Date, service: String, preflight: Bool, authValue: Int,
                responsible: TCCProcess?, accessing: TCCProcess?, requesting: TCCProcess? = nil) {
        self.date = date
        self.service = service
        self.preflight = preflight
        self.authValue = authValue
        self.responsible = responsible
        self.accessing = accessing
        self.requesting = requesting
    }

    /// The app to blame: the responsible app, else the accessing process, else the requester itself.
    public var app: String { (responsible ?? accessing ?? requesting)?.identifier ?? "unknown" }
    public var accessor: String { accessing?.identifier ?? "" }
    public var binaryPath: String { (accessing ?? responsible ?? requesting)?.binaryPath ?? "" }
}

public enum TCCService {
    private static let names: [String: String] = [
        "Camera": "Camera",
        "Microphone": "Microphone",
        "ScreenCapture": "Screen Recording",
        "AudioCapture": "System Audio Recording",
        "SystemPolicyAllFiles": "Full Disk Access",
        "SystemPolicyDocumentsFolder": "Documents Folder",
        "SystemPolicyDesktopFolder": "Desktop Folder",
        "SystemPolicyDownloadsFolder": "Downloads Folder",
        "SystemPolicyRemovableVolumes": "Removable Volumes",
        "SystemPolicyNetworkVolumes": "Network Volumes",
        "SystemPolicyAppBundles": "App Management",
        "SystemPolicyAppData": "App Data",
        "SystemPolicyAppDataDetailed": "App Data",
        "AddressBook": "Contacts",
        "Calendar": "Calendars",
        "Reminders": "Reminders",
        "Photos": "Photos",
        "Accessibility": "Accessibility",
        "ListenEvent": "Input Monitoring",
        "PostEvent": "Keyboard Control",
        "AppleEvents": "Automation",
        "BluetoothAlways": "Bluetooth",
        "DeveloperTool": "Developer Tools",
        "MediaLibrary": "Media Library",
        "SpeechRecognition": "Speech Recognition",
        "Location": "Location",
    ]

    /// `kTCCServiceSystemPolicyAllFiles` -> "Full Disk Access".
    public static func displayName(for service: String) -> String {
        let short = service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
        return names[short] ?? short
    }

    public static func isFileAccess(_ service: String) -> Bool {
        service.hasPrefix("kTCCServiceSystemPolicy")
    }

    public static func resultName(for authValue: Int) -> String {
        switch authValue {
        case 0: "Denied"
        case 1: "Unknown"
        case 2: "Allowed"
        case 3: "Limited"
        default: "Value \(authValue)"
        }
    }
}

/// Joins the three tccd lines of one permission check (context, attribution,
/// result) by `(tccd pid, msgID)`, in whatever order they arrive.
public struct TCCCorrelator: Sendable {
    private struct Partial: Sendable {
        var firstSeen: Date
        var service: String?
        var preflight = false
        var authValue: Int?
        var responsible: TCCProcess?
        var accessing: TCCProcess?
        var requesting: TCCProcess?
        var hasAttribution = false
    }

    private var pending: [String: Partial] = [:]
    private var lastPrune = Date.distantPast
    /// Incomplete checks older than this are flushed (if usable) or dropped.
    public var timeout: TimeInterval = 30

    public init() {}

    public var pendingCount: Int { pending.count }

    public mutating func consume(_ entry: LogEntry) -> [TCCAccessEvent] {
        var output = prune(now: entry.timestamp)
        let message = entry.eventMessage

        let kind: LineKind
        if message.hasPrefix(LogPredicates.tccContextPrefix) { kind = .context }
        else if message.hasPrefix(LogPredicates.tccAttributionPrefix) { kind = .attribution }
        else if message.hasPrefix(LogPredicates.tccResultPrefix) { kind = .result }
        else { return output }

        guard let msgID = Self.field("msgID", in: message) else { return output }
        let key = "\(entry.processID)|\(msgID)"
        var partial = pending[key] ?? Partial(firstSeen: entry.timestamp)

        switch kind {
        case .context:
            partial.service = Self.field("service", in: message)
            partial.preflight = Self.field("preflight", in: message) == "yes"
        case .attribution:
            partial.responsible = Self.process(role: "responsible", in: message)
            partial.accessing = Self.process(role: "accessing", in: message)
            partial.requesting = Self.process(role: "requesting", in: message)
            partial.hasAttribution = true
        case .result:
            partial.authValue = Self.field("authValue", in: message).flatMap { Int($0) }
        }

        if partial.service != nil, partial.authValue != nil, partial.hasAttribution {
            pending[key] = nil
            if let event = Self.event(from: partial, date: entry.timestamp) { output.append(event) }
        } else {
            pending[key] = partial
        }
        return output
    }

    private enum LineKind { case context, attribution, result }

    private mutating func prune(now: Date) -> [TCCAccessEvent] {
        guard now.timeIntervalSince(lastPrune) > timeout / 2 else { return [] }
        lastPrune = now
        var flushed: [TCCAccessEvent] = []
        for (key, partial) in pending where now.timeIntervalSince(partial.firstSeen) > timeout {
            pending[key] = nil
            if let event = Self.event(from: partial, date: partial.firstSeen) { flushed.append(event) }
        }
        return flushed.sorted { $0.date < $1.date }
    }

    private static func event(from partial: Partial, date: Date) -> TCCAccessEvent? {
        guard let service = partial.service, let authValue = partial.authValue else { return nil }
        return TCCAccessEvent(
            date: date,
            service: service,
            preflight: partial.preflight,
            authValue: authValue,
            responsible: partial.responsible,
            accessing: partial.accessing,
            requesting: partial.requesting
        )
    }

    // MARK: Parsing

    /// Value of `key=value` in a comma separated tccd message.
    static func field(_ key: String, in message: String) -> String? {
        var searchStart = message.startIndex
        while let range = message.range(of: "\(key)=", range: searchStart..<message.endIndex) {
            searchStart = range.upperBound
            // Only accept a whole key, not the tail of a longer one (pid vs. euid).
            if range.lowerBound > message.startIndex {
                let before = message[message.index(before: range.lowerBound)]
                guard before == " " || before == "{" || before == "," else { continue }
            }
            let rest = message[range.upperBound...]
            let end = rest.firstIndex(where: { $0 == "," || $0 == "}" }) ?? rest.endIndex
            let value = rest[..<end].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Parses `role={TCCDProcess: identifier=..., pid=..., ..., binary_path=...}`.
    static func process(role: String, in message: String) -> TCCProcess? {
        guard let start = message.range(of: "\(role)={TCCDProcess: ") else { return nil }
        let rest = message[start.upperBound...]
        guard let close = rest.firstIndex(of: "}") else { return nil }
        let body = String(rest[..<close])
        guard let identifier = field("identifier", in: "{" + body) else { return nil }
        let pid = field("pid", in: body).flatMap { Int($0) } ?? 0
        var binaryPath: String?
        if let pathRange = body.range(of: "binary_path=") {
            binaryPath = String(body[pathRange.upperBound...])
        }
        return TCCProcess(identifier: identifier, pid: pid, binaryPath: binaryPath)
    }
}
