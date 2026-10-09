import Foundation

/// Whether something the user would recognize as an app did it, or a system service.
public enum AppKind: String, CaseIterable, Sendable {
    case app
    case system
}

public enum AppClassifier {
    /// Classifies an identifier from the log.
    ///
    /// - Parameters:
    ///   - identifier: Bundle ID, or a display name such as "System Services".
    ///   - bundlePath: Where the bundle lives on disk, if it could be resolved.
    ///   - binaryPath: The executable path logged by tccd, if any.
    ///
    /// Anything inside an Applications folder is an app, including helpers
    /// nested in an app bundle and Apple's own apps such as FaceTime. Apple
    /// daemons and agents in /System, /usr and /Library/Apple are system services.
    public static func kind(identifier: String, bundlePath: String? = nil, binaryPath: String? = nil) -> AppKind {
        let paths = [bundlePath, binaryPath].compactMap { $0 }.filter { !$0.isEmpty }
        if paths.contains(where: isInApplicationsFolder) { return .app }
        if paths.contains(where: isSystemLocation) { return .system }
        // Control Center names non-bundle users ("System Services") instead of giving a bundle ID.
        if !identifier.contains(".") { return .system }
        if identifier.hasPrefix("com.apple.") { return .system }
        return .app
    }

    static func isInApplicationsFolder(_ path: String) -> Bool {
        path.contains("/Applications/")
    }

    static func isSystemLocation(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/", "/Library/Developer/CommandLineTools/"]
            .contains { path.hasPrefix($0) }
    }
}
