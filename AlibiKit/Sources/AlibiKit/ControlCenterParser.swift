import Foundation

public enum ControlCenterParser {
    /// Parses `Active activity attributions changed to ["cam:com.apple.FaceTime", ...]`.
    /// Returns nil when the message is not a snapshot line.
    public static func snapshot(from message: String) -> Set<Attribution>? {
        let prefix = LogPredicates.controlCenterSnapshotPrefix
        guard message.hasPrefix(prefix) else { return nil }
        let payload = Data(message.dropFirst(prefix.count).utf8)
        guard let items = try? JSONDecoder().decode([String].self, from: payload) else { return nil }

        var result = Set<Attribution>()
        for item in items {
            guard let colon = item.firstIndex(of: ":") else { continue }
            let tag = item[..<colon].trimmingCharacters(in: .whitespaces)
            let app = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, !app.isEmpty else { continue }
            result.insert(Attribution(sensor: Sensor(rawValue: tag), app: app))
        }
        return result
    }
}
