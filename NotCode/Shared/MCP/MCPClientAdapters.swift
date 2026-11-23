import Foundation

// MARK: - Scan & Sync Reports

struct MCPAppDiscoverySummary: Equatable {
    var app: MCPClientApp
    var configExists: Bool
    var serverCount: Int
    var extractedAuthCount: Int
}

struct MCPScanReport: Equatable {
    var scannedApps: [MCPAppDiscoverySummary]
    var newlyAdded: Int
    var updatedSources: Int
    var authVariantsCreated: Int
    var totalInPool: Int
}

struct MCPSyncAppResult: Equatable {
    var app: MCPClientApp
    var success: Bool
    var writtenCount: Int
    var errorMessage: String?
}

struct MCPSyncReport: Equatable {
    var profileName: String
    var mode: MCPSyncMode
    var results: [MCPSyncAppResult]
    var syncedAt: Date = Date()

    var succeededCount: Int { results.filter(\.success).count }
    var failedResults: [MCPSyncAppResult] { results.filter { !$0.success } }
}

// MARK: - Per-App Config Reading & Writing

enum MCPClientConfigIO {
    /// Reads all MCP servers configured in a client app's config file.
    static func readServers(from app: MCPClientApp, at customURL: URL? = nil) -> [MCPServerEntry] {
        let url = customURL ?? app.configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        switch app {
        case .codex:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return parseCodexTOML(text, source: app.rawValue)
        case .claudeCode:
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [] }
            return parseClaudeCodeJSON(root, source: app.rawValue)
        case .vscode:
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [] }
            let serversDict = (root["servers"] as? [String: Any])
                ?? (root["mcpServers"] as? [String: Any]) ?? [:]
            return parseStandardJSONServers(serversDict, source: app.rawValue, projectPath: nil)
        case .claudeDesktop, .cursor, .antigravity, .windsurf:
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [] }
            let serversDict = root["mcpServers"] as? [String: Any] ?? [:]
            return parseStandardJSONServers(serversDict, source: app.rawValue, projectPath: nil)
        }
    }

    /// Writes `servers` into a client app's config file while preserving all non-MCP settings.
    ///
    /// Only servers named in `managedNames` (the pool, case-insensitive) are replaced or removed;
    /// servers the pool does not know about are kept. A timestamped 0600 backup is written first,
    /// and a file that exists but cannot be parsed is never overwritten.
    static func writeServers(
        _ servers: [MCPServerEntry],
        to app: MCPClientApp,
        at customURL: URL? = nil,
        managedNames: Set<String>
    ) throws {
        let url = customURL ?? app.configURL
        let managed = Set((managedNames.union(servers.map(\.name))).map { $0.lowercased() })
        let existingData = FileManager.default.contents(atPath: url.path)

        let output: Data
        switch app {
        case .codex:
            let existing = existingData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            output = Data(replaceCodexMCPServers(in: existing, with: servers, managedNames: managed).utf8)
        case .vscode, .claudeCode, .claudeDesktop, .cursor, .antigravity, .windsurf:
            var root: [String: Any] = [:]
            if let existingData, !existingData.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSLocalizedDescriptionKey: "\(app.configDisplayPath) is not plain JSON (comments or trailing commas?); left untouched.",
                    ])
                }
                root = parsed
            }
            let key = app == .vscode ? "servers" : "mcpServers"
            root[key] = mergeStandardJSONServers(
                existing: root[key] as? [String: Any] ?? [:],
                servers: servers,
                managed: managed,
                app: app)
            output = Data(HookInstaller.prettyJSON(root).utf8)
        }

        if let existingData {
            if existingData == output { return }
            try backup(existingData, of: url)
        }
        // Client configs now carry credentials: write them owner-only.
        try MCPSecureFile.write(output, to: url)
    }

    /// Keeps every backup NotCode ever made unless there are many: the oldest one (the
    /// pre-NotCode original) and the newest `keepRecent` are always kept.
    static let backupKeepRecent = 10

    static func backup(_ data: Data, of url: URL) throws {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let prefix = url.lastPathComponent + ".notcode-mcp-backup-"
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(prefix + formatter.string(from: Date()))
        try MCPSecureFile.write(data, to: backupURL)

        let dir = url.deletingLastPathComponent()
        let existing = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted()
        guard existing.count > backupKeepRecent + 1 else { return }
        for name in existing.dropFirst().dropLast(backupKeepRecent) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - JSON Parsing & Encoding

    static func parseClaudeCodeJSON(_ root: [String: Any], source: String) -> [MCPServerEntry] {
        var entries: [MCPServerEntry] = []
        if let top = root["mcpServers"] as? [String: Any] {
            entries.append(contentsOf: parseStandardJSONServers(top, source: source, projectPath: nil))
        }
        if let projects = root["projects"] as? [String: Any] {
            for (projectPath, value) in projects {
                guard let projDict = value as? [String: Any],
                      let projServers = projDict["mcpServers"] as? [String: Any],
                      !projServers.isEmpty
                else { continue }
                entries.append(contentsOf: parseStandardJSONServers(
                    projServers, source: source, projectPath: projectPath))
            }
        }
        return entries
    }

    static func parseStandardJSONServers(
        _ dict: [String: Any],
        source: String,
        projectPath: String?
    ) -> [MCPServerEntry] {
        var result: [MCPServerEntry] = []
        for (name, raw) in dict {
            // Skip our own gateway entry so re-scanning doesn't pull NotCode into itself.
            if name == "notcode-hub" { continue }
            guard let obj = raw as? [String: Any] else { continue }

            let rawType = (obj["type"] as? String)?.lowercased()
            let url = (obj["url"] as? String) ?? (obj["serverUrl"] as? String)
            let command = obj["command"] as? String
            let args = (obj["args"] as? [String]) ?? []

            let transport: MCPTransport
            if rawType == "sse" {
                transport = .sse
            } else if rawType == "http" || rawType == "streamable-http" || rawType == "streamablehttp" {
                transport = .http
            } else if command != nil {
                transport = .stdio
            } else if url != nil {
                transport = .http
            } else {
                continue
            }

            let env = stringDictionary(from: obj["env"])
            let headers = stringDictionary(from: obj["headers"])
            let bearerVar = obj["bearer_token_env_var"] as? String

            result.append(MCPServerEntry(
                name: name,
                transport: transport,
                command: command,
                args: args,
                url: url,
                env: env,
                headers: headers,
                bearerTokenEnvVar: bearerVar,
                sources: [source],
                discoveredProjectPath: projectPath))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Merges `servers` into an app's existing server map. Unmanaged servers stay as they are;
    /// for a server that already exists, keys NotCode does not model (`disabled`, `autoApprove`,
    /// `cwd`, `timeout`, …) are kept.
    static func mergeStandardJSONServers(
        existing: [String: Any],
        servers: [MCPServerEntry],
        managed: Set<String>,
        app: MCPClientApp
    ) -> [String: Any] {
        let modeledKeys: Set<String> = ["type", "command", "args", "url", "serverUrl", "env", "headers"]
        var dict = existing.filter { !managed.contains($0.key.lowercased()) }
        for server in servers {
            let previous = existing.first { $0.key.lowercased() == server.name.lowercased() }?.value
            var entry = (previous as? [String: Any] ?? [:]).filter { !modeledKeys.contains($0.key) }
            for (k, v) in encodeStandardJSONServer(server, app: app) { entry[k] = v }
            dict[server.name] = entry
        }
        return dict
    }

    static func encodeStandardJSONServer(_ server: MCPServerEntry, app: MCPClientApp) -> [String: Any] {
        var entry: [String: Any] = [:]
        switch server.transport {
        case .stdio:
            if app == .vscode { entry["type"] = "stdio" }
            if let command = server.command { entry["command"] = command }
            if !server.args.isEmpty { entry["args"] = server.args }
            if !server.env.isEmpty { entry["env"] = server.env }
        case .http, .sse:
            entry["type"] = server.transport.rawValue
            // Windsurf and Antigravity read remote servers from `serverUrl`.
            let urlKey = (app == .windsurf || app == .antigravity) ? "serverUrl" : "url"
            if let url = server.url { entry[urlKey] = url }
            if !server.headers.isEmpty { entry["headers"] = server.headers }
            if !server.env.isEmpty { entry["env"] = server.env }
        }
        return entry
    }

    private static func stringDictionary(from raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String {
                out[k] = s
            } else if let n = v as? NSNumber {
                out[k] = n.stringValue
            }
        }
        return out
    }

    // MARK: - Codex TOML Parsing & Writing

    /// Parses `[mcp_servers.<name>]`, `[mcp_servers.<name>.env]`, and `[mcp_servers.<name>.http_headers]`
    /// from `~/.codex/config.toml`.
    static func parseCodexTOML(_ text: String, source: String) -> [MCPServerEntry] {
        struct Builder {
            var command: String?
            var args: [String] = []
            var url: String?
            var env: [String: String] = [:]
            var headers: [String: String] = [:]
            var bearerTokenEnvVar: String?
        }

        enum Section {
            case other
            case server(String)
            case env(String)
            case headers(String)
        }

        var builders: [String: Builder] = [:]
        var section: Section = .other

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if header.hasPrefix("mcp_servers.") {
                    let rest = String(header.dropFirst("mcp_servers.".count))
                    let parts = splitTOMLHeaderPath(rest)
                    if parts.count == 1 {
                        section = .server(parts[0])
                        if builders[parts[0]] == nil { builders[parts[0]] = Builder() }
                    } else if parts.count == 2 && parts[1] == "env" {
                        section = .env(parts[0])
                        if builders[parts[0]] == nil { builders[parts[0]] = Builder() }
                    } else if parts.count == 2 && (parts[1] == "http_headers" || parts[1] == "headers") {
                        section = .headers(parts[0])
                        if builders[parts[0]] == nil { builders[parts[0]] = Builder() }
                    } else {
                        section = .other
                    }
                } else {
                    section = .other
                }
                continue
            }

            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let rawKey = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let key = unquoteTOML(rawKey)
            let rawVal = stripInlineTOMLComment(String(line[line.index(after: eqIdx)...]))
                .trimmingCharacters(in: .whitespaces)

            switch section {
            case .other:
                continue
            case .server(let name):
                switch key {
                case "command":
                    builders[name]?.command = unquoteTOML(rawVal)
                case "url":
                    builders[name]?.url = unquoteTOML(rawVal)
                case "bearer_token_env_var":
                    builders[name]?.bearerTokenEnvVar = unquoteTOML(rawVal)
                case "args":
                    if let parsed = parseTOMLStringArray(rawVal) {
                        builders[name]?.args = parsed
                    }
                case "env":
                    for (k, v) in parseTOMLInlineTable(rawVal) {
                        builders[name]?.env[k] = v
                    }
                case "http_headers", "headers":
                    for (k, v) in parseTOMLInlineTable(rawVal) {
                        builders[name]?.headers[k] = v
                    }
                default:
                    break
                }
            case .env(let name):
                builders[name]?.env[key] = unquoteTOML(rawVal)
            case .headers(let name):
                builders[name]?.headers[key] = unquoteTOML(rawVal)
            }
        }

        var entries: [MCPServerEntry] = []
        for (name, b) in builders where name != "notcode-hub" {
            let transport: MCPTransport
            if b.command != nil {
                transport = .stdio
            } else if b.url != nil {
                transport = .http
            } else {
                continue
            }
            entries.append(MCPServerEntry(
                name: name,
                transport: transport,
                command: b.command,
                args: b.args,
                url: b.url,
                env: b.env,
                headers: b.headers,
                bearerTokenEnvVar: b.bearerTokenEnvVar,
                sources: [source]))
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Replaces the `[mcp_servers.*]` blocks of managed servers in a Codex TOML file with `servers`,
    /// preserving root keys (`notify`, `model`, etc.), every other `[table]`, and the blocks of
    /// servers outside `managedNames` (lowercased; nil means every server block is managed).
    /// A server whose parsed settings are unchanged keeps its original block verbatim, so keys
    /// NotCode does not model (`startup_timeout_sec`, `enabled`, …) survive a sync.
    static func replaceCodexMCPServers(
        in text: String,
        with servers: [MCPServerEntry],
        managedNames: Set<String>? = nil
    ) -> String {
        let existingByName = Dictionary(
            parseCodexTOML(text, source: "").map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        var keptLines: [String] = []
        var originalBlocks: [String: [String]] = [:]
        var currentServer: String?
        var skippingMCPBlock = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let header = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if header.hasPrefix("mcp_servers.") {
                    let name = splitTOMLHeaderPath(String(header.dropFirst("mcp_servers.".count)))
                        .first?.lowercased() ?? ""
                    currentServer = name
                    skippingMCPBlock = managedNames?.contains(name) ?? true
                } else {
                    currentServer = nil
                    skippingMCPBlock = header == "mcp_servers" && managedNames == nil
                }
            }
            if skippingMCPBlock {
                if let currentServer { originalBlocks[currentServer, default: []].append(line) }
            } else {
                keptLines.append(line)
            }
        }

        // Trim trailing blank lines before appending clean MCP sections.
        while keptLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            keptLines.removeLast()
        }

        var rendered: [String] = []
        for server in servers {
            let key = server.name.lowercased()
            if let previous = existingByName[key], previous.name == server.name,
               !previous.hasDifferentAuthOrEndpoint(from: server),
               previous.bearerTokenEnvVar == server.bearerTokenEnvVar,
               var block = originalBlocks[key] {
                while block.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    block.removeLast()
                }
                rendered.append(contentsOf: block)
                rendered.append("")
                continue
            }
            let safeName = formatTOMLKeySegment(server.name)
            rendered.append("[mcp_servers.\(safeName)]")
            switch server.transport {
            case .stdio:
                if let command = server.command {
                    rendered.append("command = \(quoteTOML(command))")
                }
                if !server.args.isEmpty {
                    let argsStr = server.args.map(quoteTOML).joined(separator: ", ")
                    rendered.append("args = [\(argsStr)]")
                }
            case .http, .sse:
                if let url = server.url {
                    rendered.append("url = \(quoteTOML(url))")
                }
                if let bearer = server.bearerTokenEnvVar, !bearer.isEmpty {
                    rendered.append("bearer_token_env_var = \(quoteTOML(bearer))")
                }
            }
            if !server.env.isEmpty {
                rendered.append("")
                rendered.append("[mcp_servers.\(safeName).env]")
                for k in server.env.keys.sorted() {
                    rendered.append("\(formatTOMLKeySegment(k)) = \(quoteTOML(server.env[k] ?? ""))")
                }
            }
            if !server.headers.isEmpty {
                rendered.append("")
                rendered.append("[mcp_servers.\(safeName).http_headers]")
                for k in server.headers.keys.sorted() {
                    rendered.append("\(formatTOMLKeySegment(k)) = \(quoteTOML(server.headers[k] ?? ""))")
                }
            }
            rendered.append("")
        }

        if keptLines.isEmpty {
            return rendered.joined(separator: "\n")
        }
        if rendered.isEmpty {
            return keptLines.joined(separator: "\n") + "\n"
        }
        return keptLines.joined(separator: "\n") + "\n\n" + rendered.joined(separator: "\n")
    }

    // MARK: - TOML Helpers

    private static func splitTOMLHeaderPath(_ path: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in path {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "." && !inQuotes {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func unquoteTOML(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func quoteTOML(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func formatTOMLKeySegment(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if !key.isEmpty && key.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return key
        }
        return quoteTOML(key)
    }

    private static func stripInlineTOMLComment(_ value: String) -> String {
        var inDouble = false
        var inSingle = false
        var prevBackslash = false
        var out = ""
        for ch in value {
            if ch == "\"" && !inSingle && !prevBackslash { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#" && !inDouble && !inSingle { break }
            prevBackslash = (ch == "\\" && !prevBackslash)
            out.append(ch)
        }
        return out
    }

    private static func parseTOMLStringArray(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return arr
    }

    private static func parseTOMLInlineTable(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { return [:] }
        let inner = String(trimmed.dropFirst().dropLast())
        var result: [String: String] = [:]
        // Split on commas outside quotes
        var pairs: [String] = []
        var cur = ""
        var inQuotes = false
        for ch in inner {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "," && !inQuotes {
                pairs.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { pairs.append(cur) }
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let k = unquoteTOML(String(pair[..<eq]))
            let v = unquoteTOML(String(pair[pair.index(after: eq)...]))
            if !k.isEmpty { result[k] = v }
        }
        return result
    }
}

// MARK: - Scanner (Auto-Detect + Auth Extraction)

enum MCPScanner {
    /// Scans all supported AI apps, extracts MCP servers + their auth credentials into `pool`,
    /// deduplicates across apps, and creates profile overrides when the same MCP has different auth.
    static func scanAll(
        into pool: inout MCPPool,
        apps: [MCPClientApp] = MCPClientApp.allCases,
        urlOverrides: [MCPClientApp: URL] = [:]
    ) -> MCPScanReport {
        var summaries: [MCPAppDiscoverySummary] = []
        var newlyAdded = 0
        var updatedSources = 0
        var authVariantsCreated = 0

        for app in apps {
            let url = urlOverrides[app] ?? app.configURL
            let exists = FileManager.default.fileExists(atPath: url.path)
            let discovered = exists ? MCPClientConfigIO.readServers(from: app, at: url) : []
            let authCount = discovered.filter(\.hasExtractedAuth).count
            summaries.append(MCPAppDiscoverySummary(
                app: app,
                configExists: exists,
                serverCount: discovered.count,
                extractedAuthCount: authCount))

            for entry in discovered {
                if let idx = pool.servers.firstIndex(where: {
                    $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
                }) {
                    // Merge source tags
                    for src in entry.sources where !pool.servers[idx].sources.contains(src) {
                        pool.servers[idx].sources.append(src)
                        updatedSources += 1
                    }
                    // If existing entry lacks auth and the newly discovered one has auth, enrich the pool!
                    if !pool.servers[idx].hasExtractedAuth && entry.hasExtractedAuth {
                        for (k, v) in entry.env where pool.servers[idx].env[k] == nil {
                            pool.servers[idx].env[k] = v
                        }
                        for (k, v) in entry.headers where pool.servers[idx].headers[k] == nil {
                            pool.servers[idx].headers[k] = v
                        }
                        if pool.servers[idx].bearerTokenEnvVar == nil {
                            pool.servers[idx].bearerTokenEnvVar = entry.bearerTokenEnvVar
                        }
                    } else if pool.servers[idx].hasDifferentAuthOrEndpoint(from: entry),
                              entry.hasExtractedAuth {
                        // Same MCP name, different credentials (e.g. Work vs Personal account)!
                        // Preserve as a profile override so nothing is lost.
                        let variantProfileName = entry.discoveredProjectPath.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        } ?? "\(app.shortName) Account"

                        let override = MCPCredentialOverride(
                            url: entry.url != pool.servers[idx].url ? entry.url : nil,
                            env: entry.env,
                            headers: entry.headers,
                            bearerTokenEnvVar: entry.bearerTokenEnvVar)

                        if let pIdx = pool.profiles.firstIndex(where: {
                            $0.name.caseInsensitiveCompare(variantProfileName) == .orderedSame
                        }) {
                            pool.profiles[pIdx].enabledServerNames.insert(pool.servers[idx].name)
                            pool.profiles[pIdx].overrides[pool.servers[idx].name] = override
                        } else {
                            var newProfile = MCPProfile(
                                name: variantProfileName,
                                icon: "key.fill",
                                colorName: "purple",
                                enabledServerNames: [pool.servers[idx].name],
                                includeAllByDefault: false,
                                overrides: [pool.servers[idx].name: override])
                            // Include other non-conflicting servers if desired? Keep focused on discovered ones.
                            newProfile.enabledServerNames.insert(pool.servers[idx].name)
                            pool.profiles.append(newProfile)
                            if let projPath = entry.discoveredProjectPath {
                                pool.bindProject(projPath, to: newProfile.id)
                            }
                            authVariantsCreated += 1
                        }
                    }
                } else {
                    pool.servers.append(entry)
                    newlyAdded += 1
                    // Automatically enable in Default / includeAllByDefault profiles
                    for i in pool.profiles.indices where pool.profiles[i].includeAllByDefault {
                        pool.profiles[i].enabledServerNames.insert(entry.name)
                    }
                }
            }
        }

        pool.servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        pool.lastScanDate = Date()

        return MCPScanReport(
            scannedApps: summaries,
            newlyAdded: newlyAdded,
            updatedSources: updatedSources,
            authVariantsCreated: authVariantsCreated,
            totalInPool: pool.servers.count)
    }
}

// MARK: - Syncer

enum MCPSyncer {
    /// Builds the single `notcode-hub` stdio gateway server entry for Unified Hub Gateway mode.
    static func gatewayServerEntry() -> MCPServerEntry {
        MCPServerEntry(
            name: "notcode-hub",
            transport: .stdio,
            command: Paths.installedHelper.path,
            args: ["mcp-gateway"],
            sources: ["NotCode"])
    }

    /// Syncs the active (or specified) profile to all enabled apps in `pool.enabledSyncApps`.
    static func sync(
        pool: MCPPool,
        profile: MCPProfile? = nil,
        urlOverrides: [MCPClientApp: URL] = [:]
    ) -> MCPSyncReport {
        let targetProfile = profile ?? pool.activeProfile
        let serversToWrite: [MCPServerEntry]
        switch pool.syncMode {
        case .direct:
            serversToWrite = pool.resolvedServers(for: targetProfile)
        case .gateway:
            serversToWrite = [gatewayServerEntry()]
        }

        // Only servers NotCode knows about are replaced or removed; anything else in an app stays.
        let managedNames = Set(pool.servers.map(\.name)).union(["notcode-hub"])
        var results: [MCPSyncAppResult] = []
        for app in MCPClientApp.allCases where pool.enabledSyncApps.contains(app) {
            do {
                try MCPClientConfigIO.writeServers(
                    serversToWrite, to: app, at: urlOverrides[app], managedNames: managedNames)
                results.append(MCPSyncAppResult(
                    app: app, success: true, writtenCount: serversToWrite.count))
            } catch {
                results.append(MCPSyncAppResult(
                    app: app, success: false, writtenCount: 0,
                    errorMessage: error.localizedDescription))
            }
        }

        return MCPSyncReport(
            profileName: targetProfile.name,
            mode: pool.syncMode,
            results: results)
    }

    /// Parses a pasted JSON snippet (either `{"mcpServers": {...}}` or a single server object)
    /// into one or more `MCPServerEntry` values for quick-add in the UI.
    static func parsePastedSnippet(_ jsonText: String, fallbackName: String = "custom-mcp") -> [MCPServerEntry] {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if let nested = obj["mcpServers"] as? [String: Any] {
            return MCPClientConfigIO.parseStandardJSONServers(nested, source: "Manual", projectPath: nil)
        }
        if let nested = obj["servers"] as? [String: Any] {
            return MCPClientConfigIO.parseStandardJSONServers(nested, source: "Manual", projectPath: nil)
        }
        if obj["command"] != nil || obj["url"] != nil || obj["serverUrl"] != nil {
            return MCPClientConfigIO.parseStandardJSONServers(
                [fallbackName: obj], source: "Manual", projectPath: nil)
        }
        // Maybe it's a dictionary of `{ "server-name": { "command": ... } }`
        return MCPClientConfigIO.parseStandardJSONServers(obj, source: "Manual", projectPath: nil)
    }
}
