import Foundation

/// A privacy sensor as tagged by Control Center (`cam`, `mic`, `scr`, `loc`).
/// Unknown tags from future macOS versions are kept, not dropped.
public struct Sensor: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let camera = Sensor(rawValue: "cam")
    public static let microphone = Sensor(rawValue: "mic")
    public static let screen = Sensor(rawValue: "scr")
    public static let location = Sensor(rawValue: "loc")

    public static let known: [Sensor] = [.camera, .microphone, .screen, .location]

    /// Camera, microphone and screen recording. Location is tracked but treated as low priority.
    public var isSensitive: Bool { self != .location }

    public var displayName: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screen: "Screen Recording"
        case .location: "Location"
        default: rawValue.uppercased()
        }
    }

    public var symbolName: String {
        switch self {
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .screen: "rectangle.dashed.badge.record"
        case .location: "location.fill"
        default: "questionmark.circle"
        }
    }

    public static func < (lhs: Sensor, rhs: Sensor) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// "This app is using this sensor." The app is a bundle ID, or a display name
/// when the user is not an app bundle (for example "System Services").
public struct Attribution: Hashable, Comparable, Sendable {
    public let sensor: Sensor
    public let app: String

    public init(sensor: Sensor, app: String) {
        self.sensor = sensor
        self.app = app
    }

    public static func < (lhs: Attribution, rhs: Attribution) -> Bool {
        (lhs.sensor, lhs.app) < (rhs.sensor, rhs.app)
    }
}
