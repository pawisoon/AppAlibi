import Foundation

/// Everything that depends on Apple's private log message formats lives here
/// and in the parsers (Control Center, tccd, screen lock, authd). Check these first after every macOS update.
public enum LogPredicates {
    public static let controlCenterSnapshotPrefix = "Active activity attributions changed to "

    public static let tccContextPrefix = "AUTHREQ_CTX:"
    public static let tccAttributionPrefix = "AUTHREQ_ATTRIBUTION:"
    public static let tccResultPrefix = "AUTHREQ_RESULT:"

    /// loginwindow tells the session when the screen locks and unlocks:
    /// `... | sendDistributedNotification: com.apple.screenIsLocked, with object:501`.
    /// The object is the user ID of the session.
    public static let screenLockMarker = "sendDistributedNotification: "
    public static let screenLockedName = "com.apple.screenIsLocked"
    public static let screenUnlockedName = "com.apple.screenIsUnlocked"

    /// authd logs each granted right:
    /// `Succeeded authorizing right 'system.privilege.admin' by client '/path' [pid] for authorization created by '/path' [pid] ...`.
    public static let adminRightPrefix = "Succeeded authorizing right '"

    public static let controlCenter = """
    (subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" \
    AND eventMessage BEGINSWITH "\(controlCenterSnapshotPrefix.trimmingCharacters(in: .whitespaces))")
    """

    public static let tcc = """
    (process == "tccd" AND (eventMessage BEGINSWITH "\(tccContextPrefix)" \
    OR eventMessage BEGINSWITH "\(tccAttributionPrefix)" \
    OR eventMessage BEGINSWITH "\(tccResultPrefix)"))
    """

    public static let screenLock = """
    (process == "loginwindow" AND (eventMessage CONTAINS "\(screenLockMarker)\(screenLockedName)," \
    OR eventMessage CONTAINS "\(screenLockMarker)\(screenUnlockedName),"))
    """

    public static let adminRights = """
    (process == "authd" AND eventMessage BEGINSWITH "\(adminRightPrefix)")
    """

    /// One predicate for every source, so a single `log` process delivers events in order.
    public static let combined = "\(controlCenter) OR \(tcc) OR \(screenLock) OR \(adminRights)"
}
