import Foundation

/// Lightweight, native JSON-RPC 2.0 MCP Server (stdio) embedded inside `notcode-hook mcp-gateway`.
///
/// Inspired by `samanhappy/mcphub`: lets any AI client connect once to NotCode to:
/// 1. Check which profile (Personal / Work / etc.) is active for the current project — and when
///    a project is unbound, instructs the agent to ask the user which profile to use!
/// 2. Switch profiles on the fly and persist project → profile bindings.
/// 3. Inspect all pooled MCPs + auth status and trigger a cross-app sync.
/// 4. Forward JSON-RPC tool calls to upstream HTTP/Streamable-HTTP MCP servers with the active
///    profile's resolved auth headers injected automatically.
enum MCPGateway {
    static let protocolVersion = "2024-11-05"

    /// Runs the stdio JSON-RPC loop until EOF. Never writes non-JSON-RPC output to stdout.
    static func run(projectPath: String? = nil) {
        let cwd = projectPath ?? FileManager.default.currentDirectoryPath
        Log.append("mcp-gateway: starting for project \(cwd)")

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let response = handleMessage(data, defaultProjectPath: cwd)
            else { continue }
            if let outData = try? JSONSerialization.data(withJSONObject: response, options: []),
               let outStr = String(data: outData, encoding: .utf8) {
                FileHandle.standardOutput.write(Data((outStr + "\n").utf8))
            }
        }
    }

    /// Pure request handler (unit-testable without stdio). Returns nil for notifications.
    static func handleMessage(
        _ data: Data,
        defaultProjectPath: String,
        poolURL: URL = Paths.mcpPool
    ) -> [String: Any]? {
        guard let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = req["method"] as? String
        else { return nil }

        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]

        // Notifications have no `id` and expect no response.
        if id == nil {
            return nil
        }

        switch method {
        case "initialize":
            return ok(id: id!, result: [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": ["listChanged": true]
                ],
                "serverInfo": [
                    "name": "notcode-mcp-hub",
                    "version": "1.4.0",
                ],
                "instructions": """
                NotCode MCP Hub manages your unified MCP pool and profiles (e.g. Personal, Work).
                At the start of a conversation in a project, call `notcode_get_profile` to check if this \
                project is bound to a profile. If `isBound` is false and `askProfileForNewProjects` is true, \
                ask the user which profile they want to use and call `notcode_set_profile`.
                """,
            ])

        case "ping":
            return ok(id: id!, result: [:])

        case "tools/list":
            return ok(id: id!, result: ["tools": toolDefinitions()])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return handleToolCall(
                id: id!, name: toolName, arguments: args,
                defaultProjectPath: defaultProjectPath, poolURL: poolURL)

        default:
            return errorResponse(id: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tool Definitions

    static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "notcode_get_profile",
                "description": "Check the active NotCode MCP profile for this project/conversation and list all available profiles. If the project is unbound, ask the user which profile to activate.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "projectPath": [
                            "type": "string",
                            "description": "Optional workspace path; defaults to the current working directory."
                        ]
                    ]
                ],
            ],
            [
                "name": "notcode_set_profile",
                "description": "Switch the active MCP profile (e.g. Personal, Work, Default) for this project/conversation, optionally saving the project binding and syncing connected AI apps.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "profile": [
                            "type": "string",
                            "description": "Name of the profile to activate (e.g. Personal, Work, Default)."
                        ],
                        "projectPath": [
                            "type": "string",
                            "description": "Optional project directory to bind to this profile."
                        ],
                        "rememberForProject": [
                            "type": "boolean",
                            "description": "If true (default), bind this project folder to the chosen profile for future conversations."
                        ],
                        "syncApps": [
                            "type": "boolean",
                            "description": "If true (default), immediately sync the profile's MCPs to all connected apps."
                        ],
                    ],
                    "required": ["profile"],
                ],
            ],
            [
                "name": "notcode_list_mcps",
                "description": "List all MCP servers in NotCode's unified pool, including transport, source apps, masked auth status, and whether each is enabled in the active profile.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "profile": [
                            "type": "string",
                            "description": "Optional profile name to inspect; defaults to the active profile."
                        ]
                    ]
                ],
            ],
            [
                "name": "notcode_sync_apps",
                "description": "Sync the active profile's MCP servers and credentials across all connected AI apps (Claude Code, Cursor, Codex, etc.).",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ],
            ],
            [
                "name": "notcode_call_upstream",
                "description": "Proxy a JSON-RPC MCP tool call to an upstream HTTP/SSE MCP server in the active profile, automatically injecting that profile's resolved authentication headers.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "server": [
                            "type": "string",
                            "description": "Name of the HTTP/SSE MCP server in the pool."
                        ],
                        "tool": [
                            "type": "string",
                            "description": "Upstream tool name to invoke."
                        ],
                        "arguments": [
                            "type": "object",
                            "description": "Tool arguments object."
                        ],
                    ],
                    "required": ["server", "tool"],
                ],
            ],
        ]
    }

    // MARK: - Tool Execution

    private static func handleToolCall(
        id: Any,
        name: String,
        arguments: [String: Any],
        defaultProjectPath: String,
        poolURL: URL
    ) -> [String: Any] {
        var pool = MCPPoolStore.load(from: poolURL)

        switch name {
        case "notcode_get_profile":
            let project = (arguments["projectPath"] as? String) ?? defaultProjectPath
            let (effective, isBound) = pool.effectiveProfile(forProjectPath: project)
            let profileNames = pool.profiles.map(\.name)
            let servers = pool.resolvedServers(for: effective).map(\.name)
            let promptHint: String
            if !isBound && pool.askProfileForNewProjects && pool.profiles.count > 1 {
                promptHint = "This project is NOT bound to a profile yet. Ask the user which profile they want to use (\(profileNames.joined(separator: ", "))) and then call `notcode_set_profile`."
            } else {
                promptHint = "Using profile '\(effective.name)' (\(isBound ? "bound to this project" : "global default"))."
            }
            let payload: [String: Any] = [
                "projectPath": project,
                "activeProfile": effective.name,
                "isBound": isBound,
                "askProfileForNewProjects": pool.askProfileForNewProjects,
                "availableProfiles": profileNames,
                "enabledServers": servers,
                "guidance": promptHint,
            ]
            return toolTextResult(id: id, jsonObject: payload)

        case "notcode_set_profile":
            guard let requested = arguments["profile"] as? String,
                  let chosen = pool.profile(named: requested)
            else {
                let names = pool.profiles.map(\.name).joined(separator: ", ")
                return toolTextResult(
                    id: id,
                    text: "Profile not found. Available profiles: \(names)",
                    isError: true)
            }
            let project = (arguments["projectPath"] as? String) ?? defaultProjectPath
            let remember = (arguments["rememberForProject"] as? Bool) ?? true
            let shouldSync = (arguments["syncApps"] as? Bool) ?? true

            pool.activeProfileID = chosen.id
            if remember && !project.isEmpty {
                pool.bindProject(project, to: chosen.id)
            }
            var syncSummary = "skipped"
            if shouldSync {
                let report = MCPSyncer.sync(pool: pool, profile: chosen)
                pool.lastSyncDate = report.syncedAt
                syncSummary = "\(report.succeededCount)/\(report.results.count) apps synced"
            }
            try? MCPPoolStore.save(pool, to: poolURL)
            let resolved = pool.resolvedServers(for: chosen).map(\.name)
            return toolTextResult(id: id, jsonObject: [
                "activeProfile": chosen.name,
                "boundProject": remember ? project : NSNull(),
                "enabledServers": resolved,
                "sync": syncSummary,
            ])

        case "notcode_list_mcps":
            let profile: MCPProfile
            if let requested = arguments["profile"] as? String,
               let found = pool.profile(named: requested) {
                profile = found
            } else {
                profile = pool.effectiveProfile(forProjectPath: defaultProjectPath).profile
            }
            let items: [[String: Any]] = pool.servers.map { server in
                [
                    "name": server.name,
                    "transport": server.transport.rawValue,
                    "endpoint": server.endpointPreview,
                    "sources": server.sources,
                    "hasAuth": server.hasExtractedAuth,
                    "authSummary": server.authSummary,
                    "enabledInProfile": profile.includes(serverName: server.name),
                    "hasProfileOverride": profile.overrides[server.name] != nil,
                ]
            }
            return toolTextResult(id: id, jsonObject: [
                "profile": profile.name,
                "totalServers": pool.servers.count,
                "servers": items,
            ])

        case "notcode_sync_apps":
            let report = MCPSyncer.sync(pool: pool)
            pool.lastSyncDate = report.syncedAt
            try? MCPPoolStore.save(pool, to: poolURL)
            let appResults = report.results.map { r -> [String: Any] in
                [
                    "app": r.app.rawValue,
                    "success": r.success,
                    "writtenCount": r.writtenCount,
                    "error": r.errorMessage ?? NSNull(),
                ]
            }
            return toolTextResult(id: id, jsonObject: [
                "profile": report.profileName,
                "mode": report.mode.rawValue,
                "results": appResults,
            ])

        case "notcode_call_upstream":
            guard let serverName = arguments["server"] as? String,
                  let toolName = arguments["tool"] as? String
            else {
                return toolTextResult(id: id, text: "Missing 'server' or 'tool' parameter.", isError: true)
            }
            let (profile, _) = pool.effectiveProfile(forProjectPath: defaultProjectPath)
            let resolved = pool.resolvedServers(for: profile)
            guard let server = resolved.first(where: {
                $0.name.caseInsensitiveCompare(serverName) == .orderedSame
            }) else {
                return toolTextResult(
                    id: id,
                    text: "Server '\(serverName)' is not enabled in profile '\(profile.name)'.",
                    isError: true)
            }
            guard server.transport != .stdio,
                  let urlStr = server.url,
                  let url = URL(string: urlStr)
            else {
                return toolTextResult(
                    id: id,
                    text: "Upstream proxying currently supports HTTP/SSE servers; '\(server.name)' is \(server.transport.rawValue).",
                    isError: true)
            }
            let toolArgs = arguments["arguments"] as? [String: Any] ?? [:]
            return forwardHTTPUpstream(id: id, url: url, headers: server.headers,
                                       tool: toolName, arguments: toolArgs)

        default:
            return toolTextResult(id: id, text: "Unknown tool: \(name)", isError: true)
        }
    }

    private static func forwardHTTPUpstream(
        id: Any,
        url: URL,
        headers: [String: String],
        tool: String,
        arguments: [String: Any]
    ) -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseText = ""
        var failed = false
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                failed = true
                responseText = "Upstream request failed: \(error.localizedDescription)"
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !(200..<300).contains(status) {
                failed = true
                responseText = "Upstream HTTP \(status): \(raw)"
            } else {
                responseText = raw
            }
        }.resume()
        semaphore.wait()
        return toolTextResult(id: id, text: responseText, isError: failed)
    }

    // MARK: - JSON-RPC Framing

    private static func ok(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func toolTextResult(id: Any, jsonObject: [String: Any], isError: Bool = false) -> [String: Any] {
        let text = HookInstaller.prettyJSON(jsonObject)
        return toolTextResult(id: id, text: text, isError: isError)
    }

    private static func toolTextResult(id: Any, text: String, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            "content": [["type": "text", "text": text]]
        ]
        if isError { result["isError"] = true }
        return ok(id: id, result: result)
    }
}
