import Foundation

/// Everything that depends on Apple's private log message formats lives here
/// and in the two parsers. Check these first after every macOS update.
public enum LogPredicates {
    public static let controlCenterSnapshotPrefix = "Active activity attributions changed to "

    public static let tccContextPrefix = "AUTHREQ_CTX:"
    public static let tccAttributionPrefix = "AUTHREQ_ATTRIBUTION:"
    public static let tccResultPrefix = "AUTHREQ_RESULT:"

    public static let controlCenter = """
    (subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" \
    AND eventMessage BEGINSWITH "\(controlCenterSnapshotPrefix.trimmingCharacters(in: .whitespaces))")
    """

    public static let tcc = """
    (process == "tccd" AND (eventMessage BEGINSWITH "\(tccContextPrefix)" \
    OR eventMessage BEGINSWITH "\(tccAttributionPrefix)" \
    OR eventMessage BEGINSWITH "\(tccResultPrefix)"))
    """

    /// One predicate for both sources, so a single `log` process delivers events in order.
    public static let combined = "\(controlCenter) OR \(tcc)"
}
