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
    /// Localized when first read, in the language the app runs in.
    private static let names: [String: String] = [
        "Camera": String(localized: "Camera", bundle: .module),
        "Microphone": String(localized: "Microphone", bundle: .module),
        "ScreenCapture": String(localized: "Screen Recording", bundle: .module),
        "AudioCapture": String(localized: "System Audio Recording", bundle: .module),
        "SystemPolicyAllFiles": String(localized: "Full Disk Access", bundle: .module),
        "SystemPolicyDocumentsFolder": String(localized: "Documents Folder", bundle: .module),
        "SystemPolicyDesktopFolder": String(localized: "Desktop Folder", bundle: .module),
        "SystemPolicyDownloadsFolder": String(localized: "Downloads Folder", bundle: .module),
        "SystemPolicyRemovableVolumes": String(localized: "Removable Volumes", bundle: .module),
        "SystemPolicyNetworkVolumes": String(localized: "Network Volumes", bundle: .module),
        "SystemPolicyAppBundles": String(localized: "App Management", bundle: .module),
        "SystemPolicyAppData": String(localized: "App Data", bundle: .module),
        "SystemPolicyAppDataDetailed": String(localized: "App Data", bundle: .module),
        "AddressBook": String(localized: "Contacts", bundle: .module),
        "Calendar": String(localized: "Calendars", bundle: .module),
        "Reminders": String(localized: "Reminders", bundle: .module),
        "Photos": String(localized: "Photos", bundle: .module),
        "Accessibility": String(localized: "Accessibility", bundle: .module),
        "ListenEvent": String(localized: "Input Monitoring", bundle: .module),
        "PostEvent": String(localized: "Keyboard Control", bundle: .module),
        "AppleEvents": String(localized: "Automation", bundle: .module),
        "BluetoothAlways": String(localized: "Bluetooth", bundle: .module),
        "DeveloperTool": String(localized: "Developer Tools", bundle: .module),
        "MediaLibrary": String(localized: "Media Library", bundle: .module),
        "SpeechRecognition": String(localized: "Speech Recognition", bundle: .module),
        "Location": String(localized: "Location", bundle: .module),
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
        case 0: String(localized: "Denied", bundle: .module)
        case 1: String(localized: "Unknown", bundle: .module)
        case 2: String(localized: "Allowed", bundle: .module)
        case 3: String(localized: "Limited", bundle: .module)
        default: String(localized: "Value \(authValue)", bundle: .module)
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
