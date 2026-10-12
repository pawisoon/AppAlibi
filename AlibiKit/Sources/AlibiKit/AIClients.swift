import Foundation

/// An AI assistant or coding agent, recognized by the bundle IDs and paths it
/// shows up with in the log.
public struct AIClient: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Exact bundle IDs, or prefixes ending in `*`.
    public let bundleIDs: [String]
    /// Path parts that only this client's binaries have.
    public let pathFragments: [String]
    /// Executable names (the last path component), for CLIs installed anywhere.
    public let binaryNames: [String]
    /// Added by the user in Settings.
    public let isCustom: Bool

    public init(id: String, name: String, bundleIDs: [String] = [], pathFragments: [String] = [],
                binaryNames: [String] = [], isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.pathFragments = pathFragments
        self.binaryNames = binaryNames
        self.isCustom = isCustom
    }

    /// A user's own pick: an app by bundle ID, or any executable by path.
    public static func custom(name: String, bundleID: String?, path: String) -> AIClient {
        if let bundleID, !bundleID.isEmpty {
            return AIClient(id: "custom:\(bundleID)", name: name, bundleIDs: [bundleID, "\(bundleID).*"], isCustom: true)
        }
        return AIClient(id: "custom:\(path)", name: name, pathFragments: [path], isCustom: true)
    }

    public func matches(identifier: String) -> Bool {
        bundleIDs.contains { pattern in
            pattern.hasSuffix("*") ? identifier.hasPrefix(pattern.dropLast()) : identifier == pattern
        }
    }

    public func matches(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if pathFragments.contains(where: path.contains) { return true }
        let name = (path as NSString).lastPathComponent
        return binaryNames.contains(name)
    }

    public func matches(identifier: String, path: String?) -> Bool {
        matches(identifier: identifier) || path.map(matches(path:)) == true
    }
}

/// The known AI clients, plus the user's own. The first client that matches wins.
///
/// IDs checked against real tccd and Control Center lines on macOS 27.0.1
/// (2026-10-12): Claude Code, Claude, Kimi, Perplexity (`ai.perplexity.mac`) and
/// Comet. The rest come from Homebrew casks and vendor issues.
public struct AIClientCatalog: Hashable, Sendable {
    public let clients: [AIClient]

    public init(_ clients: [AIClient]) {
        self.clients = clients
    }

    public static let builtIn = AIClientCatalog([
        // Before Claude: the desktop app bundles Claude Code under its own Application Support folder.
        AIClient(id: "claude-code", name: "Claude Code",
                 bundleIDs: ["com.anthropic.claude-code"],
                 pathFragments: ["/.local/share/claude/versions/", "/Application Support/Claude/claude-code/",
                                 "/node_modules/@anthropic-ai/claude-code/"]),
        AIClient(id: "claude", name: "Claude",
                 bundleIDs: ["com.anthropic.claudefordesktop*", "com.anthropic.claude.*"],
                 pathFragments: ["/Claude.app/", "/Application Support/Claude/scratch-workspaces/"]),
        AIClient(id: "openai", name: "ChatGPT & Codex",
                 bundleIDs: ["com.openai.*"],
                 pathFragments: ["/ChatGPT.app/", "/Codex.app/", "/node_modules/@openai/codex/", "/Cellar/codex/"],
                 binaryNames: ["codex"]),
        AIClient(id: "copilot", name: "GitHub Copilot",
                 bundleIDs: ["com.github.CopilotForXcode*"],
                 pathFragments: ["/node_modules/@github/copilot/"],
                 binaryNames: ["copilot"]),
        AIClient(id: "kimi", name: "Kimi",
                 bundleIDs: ["com.moonshot.*"],
                 pathFragments: ["/.kimi-code/", "/Kimi.app/"],
                 binaryNames: ["kimi"]),
        AIClient(id: "gemini", name: "Gemini",
                 bundleIDs: ["com.google.GeminiMacOS*"],
                 pathFragments: ["/node_modules/@google/gemini-cli/", "/Cellar/gemini-cli/"],
                 binaryNames: ["gemini"]),
        AIClient(id: "cursor", name: "Cursor",
                 bundleIDs: ["com.todesktop.230313mzl4w4u92*"],
                 pathFragments: ["/Cursor.app/"]),
        AIClient(id: "perplexity", name: "Perplexity",
                 bundleIDs: ["ai.perplexity.*"],
                 pathFragments: ["/Perplexity.app/", "/Comet.app/"],
                 binaryNames: ["perplexityd"]),
        AIClient(id: "windsurf", name: "Windsurf",
                 bundleIDs: ["com.exafunction.windsurf*"],
                 pathFragments: ["/Windsurf.app/"]),
        AIClient(id: "ollama", name: "Ollama",
                 bundleIDs: ["com.electron.ollama*", "com.ollama.*"],
                 pathFragments: ["/Ollama.app/"],
                 binaryNames: ["ollama"]),
        AIClient(id: "lmstudio", name: "LM Studio",
                 bundleIDs: ["ai.elementlabs.lmstudio*"],
                 pathFragments: ["/LM Studio.app/"],
                 binaryNames: ["lms"]),
    ])

    /// The user's clients come first, so a pick can claim an app the catalog files elsewhere.
    public func adding(_ custom: [AIClient]) -> AIClientCatalog {
        let ids = Set(custom.map(\.id))
        return AIClientCatalog(custom + clients.filter { !ids.contains($0.id) })
    }

    public func client(id: String) -> AIClient? {
        clients.first { $0.id == id }
    }

    public func client(identifier: String, path: String? = nil) -> AIClient? {
        clients.first { $0.matches(identifier: identifier, path: path) }
    }

    /// A stored permission row: the app to blame, the process that accessed, and the logged binary.
    public func client(app: String, accessor: String, binaryPath: String) -> AIClient? {
        clients.first { client in
            client.matches(identifier: app) || (!accessor.isEmpty && client.matches(identifier: accessor))
                || client.matches(path: binaryPath)
        }
    }

    /// The responsible process first: a CLI agent's helpers (git, a shell) carry it as responsible.
    public func client(for event: TCCAccessEvent) -> AIClient? {
        for process in [event.responsible, event.accessing, event.requesting].compactMap({ $0 }) {
            if let client = client(identifier: process.identifier, path: process.binaryPath) { return client }
        }
        return nil
    }

    /// authd logs paths only: the app that created the authorization, then the one that asked.
    public func client(for event: AdminRightEvent) -> AIClient? {
        clients.first { $0.matches(path: event.creator) || $0.matches(path: event.client) }
    }
}
