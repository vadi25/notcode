import Foundation

// MARK: - Transport & Auth

/// How an MCP server is reached.
enum MCPTransport: String, Codable, CaseIterable, Identifiable, Equatable {
    case stdio
    case http
    case sse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "HTTP"
        case .sse: return "SSE"
        }
    }
}

/// Supported AI coding apps whose MCP configurations NotCode can discover and sync.
enum MCPClientApp: String, Codable, CaseIterable, Identifiable, Hashable {
    case claudeCode = "Claude Code"
    case claudeDesktop = "Claude Desktop"
    case cursor = "Cursor"
    case codex = "Codex"
    case antigravity = "Antigravity"
    case windsurf = "Windsurf"
    case vscode = "VS Code"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .claudeDesktop: return "Claude App"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .windsurf: return "Windsurf"
        case .vscode: return "VS Code"
        }
    }

    var configURL: URL {
        let home = Paths.home
        switch self {
        case .claudeCode:
            return home.appendingPathComponent(".claude.json")
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        case .antigravity:
            return home.appendingPathComponent(".gemini/antigravity/mcp_config.json")
        case .windsurf:
            return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        case .vscode:
            return home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        }
    }

    var configDisplayPath: String {
        let homePath = Paths.home.path
        let full = configURL.path
        if full.hasPrefix(homePath) {
            return "~" + full.dropFirst(homePath.count)
        }
        return full
    }

    var systemImage: String {
        switch self {
        case .claudeCode: return "terminal.fill"
        case .claudeDesktop: return "bubble.left.and.bubble.right.fill"
        case .cursor: return "cursorarrow.rays"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "sparkles"
        case .windsurf: return "wind"
        case .vscode: return "laptopcomputer"
        }
    }
}

/// How NotCode pushes the active profile to connected AI apps.
enum MCPSyncMode: String, Codable, CaseIterable, Identifiable {
    /// Writes each enabled server (with profile-resolved auth) directly into every app's config.
    case direct
    /// Writes a single `notcode-hub` stdio entry pointing to `notcode-hook mcp-gateway`,
    /// exposing profile tools + routing from one unified hub (like mcphub).
    case gateway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "Direct Sync"
        case .gateway: return "Unified Hub Gateway"
        }
    }

    var subtitle: String {
        switch self {
        case .direct:
            return "Writes the active profile's MCP servers and credentials straight into each app's config."
        case .gateway:
            return "Connects every app once to NotCode's built-in MCP Hub gateway (profile-aware per project)."
        }
    }
}

// MARK: - Pooled MCP Server

/// One MCP server stored in NotCode's unified pool, including any extracted auth credentials.
struct MCPServerEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Server key used in client configs (e.g. "firecrawl", "linear", "aws-mcp").
    var name: String
    var transport: MCPTransport
    // stdio fields
    var command: String?
    var args: [String] = []
    // http / sse fields
    var url: String?
    /// Environment variables (including extracted API keys, tokens, AWS profiles, etc.).
    var env: [String: String] = [:]
    /// HTTP headers (including Authorization, x-api-key, etc.).
    var headers: [String: String] = [:]
    /// Codex-style bearer token env var reference (e.g. `bearer_token_env_var`).
    var bearerTokenEnvVar: String?
    /// Apps where this server was discovered (or `["Manual"]`).
    var sources: [String] = []
    /// Optional project path if discovered inside a project-scoped config (e.g. Claude Code projects).
    var discoveredProjectPath: String?
    var discoveredAt: Date = Date()
    var notes: String = ""

    /// Whether any authentication material (headers, secret env vars, bearer var, or URL token) is present.
    var hasExtractedAuth: Bool {
        if !headers.isEmpty { return true }
        if let bearer = bearerTokenEnvVar, !bearer.isEmpty { return true }
        if env.keys.contains(where: { MCPAuthDetector.isSensitiveKey($0) }) { return true }
        if let url, MCPAuthDetector.urlContainsAuth(url) { return true }
        return false
    }

    /// Short human-readable summary of extracted auth (never reveals secret values).
    var authSummary: String {
        var parts: [String] = []
        if !headers.isEmpty {
            parts.append("\(headers.count) header\(headers.count == 1 ? "" : "s")")
        }
        let secretEnvs = env.keys.filter { MCPAuthDetector.isSensitiveKey($0) }
        if !secretEnvs.isEmpty {
            parts.append("\(secretEnvs.count) key\(secretEnvs.count == 1 ? "" : "s")")
        }
        if let bearer = bearerTokenEnvVar, !bearer.isEmpty {
            parts.append("$\(bearer)")
        }
        if parts.isEmpty, let url, MCPAuthDetector.urlContainsAuth(url) {
            parts.append("URL token")
        }
        return parts.isEmpty ? "No credentials" : parts.joined(separator: " · ")
    }

    /// Endpoint preview for list rows (command + args or URL with secrets redacted).
    var endpointPreview: String {
        switch transport {
        case .stdio:
            let cmd = command ?? ""
            let joined = ([cmd] + MCPAuthDetector.redactArgs(args))
                .filter { !$0.isEmpty }.joined(separator: " ")
            return joined.isEmpty ? "(no command)" : joined
        case .http, .sse:
            return MCPAuthDetector.redactURL(url ?? "(no url)")
        }
    }

    /// Structural fingerprint ignoring credentials, used to recognize the same server across apps.
    var identitySignature: String {
        switch transport {
        case .stdio:
            return "stdio:\(command ?? "")|\(args.joined(separator: " "))"
        case .http, .sse:
            let base = url?.components(separatedBy: "?").first ?? ""
            return "\(transport.rawValue):\(base)"
        }
    }

    /// True if credentials or endpoint differ from another entry with the same name.
    func hasDifferentAuthOrEndpoint(from other: MCPServerEntry) -> Bool {
        env != other.env
            || headers != other.headers
            || bearerTokenEnvVar != other.bearerTokenEnvVar
            || url != other.url
            || command != other.command
            || args != other.args
    }
}

// MARK: - Auth Detection & Redaction

enum MCPAuthDetector {
    private static let sensitiveFragments = [
        "KEY", "TOKEN", "SECRET", "PASS", "AUTH", "CREDENTIAL",
        "COOKIE", "BEARER", "PRIVATE", "PAT", "API", "ACCESS", "CLIENT_ID",
    ]

    static func isSensitiveKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return sensitiveFragments.contains { upper.contains($0) }
    }

    static func urlContainsAuth(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        if components.user != nil || components.password != nil { return true }
        if let items = components.queryItems {
            return items.contains { isSensitiveKey($0.name) }
        }
        return false
    }

    static func mask(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 4)) }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

    static func redactURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        if components.password != nil { components.password = "••••" }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                isSensitiveKey(item.name) ? URLQueryItem(name: item.name, value: "••••") : item
            }
        }
        return components.string ?? urlString
    }

    /// Masks secrets passed on a command line: `--api-key X`, `--token=X`,
    /// `Authorization: Bearer X`, `KEY=VALUE`, and tokens in URL query strings.
    static func redactArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        for arg in args {
            if maskNext {
                maskNext = false
                if !arg.hasPrefix("-") {
                    out.append("••••")
                    continue
                }
            }
            if arg.hasPrefix("-"), !arg.contains("=") {
                maskNext = isSensitiveKey(arg)
                out.append(arg)
            } else if let eq = arg.firstIndex(of: "="), isSensitiveKey(String(arg[..<eq])) {
                out.append("\(arg[..<eq])=••••")
            } else if let colon = arg.firstIndex(of: ":"), !arg.contains("://"),
                      isSensitiveKey(String(arg[..<colon])) {
                out.append("\(arg[..<colon]): ••••")
            } else if arg.contains("://") {
                out.append(redactURL(arg))
            } else {
                out.append(arg)
            }
        }
        return out
    }
}

// MARK: - Profiles & Project Bindings

/// Per-profile credential or endpoint override for a pooled server
/// (e.g. Personal GitHub PAT vs Work GitHub PAT, or Personal vs Work AWS_PROFILE).
struct MCPCredentialOverride: Codable, Equatable {
    var url: String?
    var env: [String: String] = [:]
    var headers: [String: String] = [:]
    var bearerTokenEnvVar: String?

    var isEmpty: Bool {
        (url == nil || url?.isEmpty == true)
            && env.isEmpty
            && headers.isEmpty
            && (bearerTokenEnvVar == nil || bearerTokenEnvVar?.isEmpty == true)
    }
}

/// A named profile (e.g. Default, Personal, Work) controlling which MCPs are active
/// and which account/API credentials they use.
struct MCPProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "person.crop.circle.fill"
    var colorName: String = "indigo"
    /// Explicit allow-list of server names enabled in this profile.
    var enabledServerNames: Set<String> = []
    /// When true, newly discovered servers are automatically enabled in this profile.
    var includeAllByDefault: Bool = false
    /// Server name → credential/endpoint overrides for this profile.
    var overrides: [String: MCPCredentialOverride] = [:]

    func includes(serverName: String) -> Bool {
        includeAllByDefault ? true : enabledServerNames.contains(serverName)
    }
}

/// Binds a local project folder (cwd) to a specific MCP profile.
struct MCPProjectBinding: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var projectPath: String
    var profileID: UUID
    var updatedAt: Date = Date()

    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }
}

// MARK: - Pool Store

/// Unified MCP Hub state persisted at ~/Library/Application Support/NotCode/mcp-pool.json (0600).
struct MCPPool: Codable, Equatable {
    var servers: [MCPServerEntry] = []
    var profiles: [MCPProfile] = []
    var activeProfileID: UUID
    var projectBindings: [MCPProjectBinding] = []
    var enabledSyncApps: Set<MCPClientApp> = [.claudeCode, .cursor, .codex]
    var syncMode: MCPSyncMode = .direct
    /// When true, NotCode prompts the user to choose a profile when an agent works in an unbound project. Off by default: new projects use the active profile.
    var askProfileForNewProjects: Bool = false
    var lastScanDate: Date?
    var lastSyncDate: Date?

    init() {
        let defaultProfile = MCPProfile(
            name: "Default",
            icon: "sparkles",
            colorName: "indigo",
            includeAllByDefault: true)
        let personalProfile = MCPProfile(
            name: "Personal",
            icon: "house.fill",
            colorName: "teal",
            includeAllByDefault: false)
        let workProfile = MCPProfile(
            name: "Work",
            icon: "briefcase.fill",
            colorName: "orange",
            includeAllByDefault: false)
        self.profiles = [defaultProfile, personalProfile, workProfile]
        self.activeProfileID = defaultProfile.id
    }

    var activeProfile: MCPProfile {
        profiles.first(where: { $0.id == activeProfileID })
            ?? profiles.first
            ?? MCPProfile(name: "Default", includeAllByDefault: true)
    }

    func profile(byID id: UUID) -> MCPProfile? {
        profiles.first { $0.id == id }
    }

    func profile(named name: String) -> MCPProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Finds the most specific binding whose `projectPath` matches or is a parent of `cwd`.
    func binding(forProjectPath cwd: String) -> MCPProjectBinding? {
        let normalized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return projectBindings
            .filter { binding in
                let base = URL(fileURLWithPath: binding.projectPath).standardizedFileURL.path
                return normalized == base || normalized.hasPrefix(base + "/")
            }
            .max(by: { $0.projectPath.count < $1.projectPath.count })
    }

    /// Resolves the profile to use for a project directory, falling back to `activeProfile`.
    func effectiveProfile(forProjectPath cwd: String?) -> (profile: MCPProfile, isBound: Bool) {
        if let cwd, !cwd.isEmpty,
           let binding = binding(forProjectPath: cwd),
           let boundProfile = profile(byID: binding.profileID) {
            return (boundProfile, true)
        }
        return (activeProfile, false)
    }

    /// Returns the enabled servers for `profile` with any per-profile credential overrides merged in.
    func resolvedServers(for profile: MCPProfile? = nil) -> [MCPServerEntry] {
        let target = profile ?? activeProfile
        return servers
            .filter { target.includes(serverName: $0.name) }
            .map { entry in
                guard let override = target.overrides[entry.name], !override.isEmpty else {
                    return entry
                }
                var resolved = entry
                if let url = override.url, !url.isEmpty {
                    resolved.url = url
                }
                for (k, v) in override.env {
                    resolved.env[k] = v
                }
                for (k, v) in override.headers {
                    resolved.headers[k] = v
                }
                if let bearer = override.bearerTokenEnvVar, !bearer.isEmpty {
                    resolved.bearerTokenEnvVar = bearer
                }
                return resolved
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    mutating func bindProject(_ path: String, to profileID: UUID) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let idx = projectBindings.firstIndex(where: {
            URL(fileURLWithPath: $0.projectPath).standardizedFileURL.path == normalized
        }) {
            projectBindings[idx].profileID = profileID
            projectBindings[idx].updatedAt = Date()
        } else {
            projectBindings.append(MCPProjectBinding(projectPath: normalized, profileID: profileID))
        }
    }

    mutating func unbindProject(id: UUID) {
        projectBindings.removeAll { $0.id == id }
    }

    mutating func setServer(_ serverName: String, enabled: Bool, in profileID: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        if profiles[idx].includeAllByDefault && !enabled {
            // Materialize the explicit set when toggling one server off in an "include all" profile.
            profiles[idx].includeAllByDefault = false
            profiles[idx].enabledServerNames = Set(servers.map(\.name))
            profiles[idx].enabledServerNames.remove(serverName)
        } else if enabled {
            profiles[idx].enabledServerNames.insert(serverName)
        } else {
            profiles[idx].enabledServerNames.remove(serverName)
        }
    }
}

// MARK: - Persistence

enum MCPPoolStore {
    static func load(from url: URL = Paths.mcpPool) -> MCPPool {
        guard let data = try? Data(contentsOf: url),
              let pool = try? JSONDecoder().decode(MCPPool.self, from: data)
        else { return MCPPool() }
        return pool
    }

    static func save(_ pool: MCPPool, to url: URL = Paths.mcpPool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Pool contains extracted API keys / auth headers; keep owner-readable only.
        try MCPSecureFile.write(try encoder.encode(pool), to: url)
    }
}

/// Writes files that hold credentials: owner-only (0600) from the first byte, then an atomic rename.
enum MCPSecureFile {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// Signal written by `notcode-hook` when an agent runs in an unbound project
/// so the menu bar app can prompt the user to pick a profile.
struct PendingProfilePrompt: Codable, Equatable {
    var projectPath: String
    var agent: String
    var detectedAt: Date = Date()
}

enum PendingProfilePromptStore {
    static func write(_ prompt: PendingProfilePrompt, to url: URL = Paths.pendingProfilePrompt) {
        Paths.ensureAppSupportExists()
        if let data = try? JSONEncoder().encode(prompt) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func consume(from url: URL = Paths.pendingProfilePrompt) -> PendingProfilePrompt? {
        guard let data = try? Data(contentsOf: url),
              let prompt = try? JSONDecoder().decode(PendingProfilePrompt.self, from: data)
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return prompt
    }
}
