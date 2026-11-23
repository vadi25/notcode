import SwiftUI

// MARK: - MCP Hub Settings Pane

struct MCPHubSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var searchText = ""
    @State private var filter: ServerFilter = .all
    @State private var editingServer: MCPServerEntry?
    @State private var showingAddSheet = false

    private enum ServerFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case stdio = "stdio"
        case remote = "HTTP/SSE"
        case withAuth = "Has Auth"
        var id: String { rawValue }
    }

    private var filteredServers: [MCPServerEntry] {
        state.mcpPool.servers.filter { server in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .stdio: matchesFilter = server.transport == .stdio
            case .remote: matchesFilter = server.transport != .stdio
            case .withAuth: matchesFilter = server.hasExtractedAuth
            }
            guard matchesFilter else { return false }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            return server.name.localizedCaseInsensitiveContains(q)
                || server.endpointPreview.localizedCaseInsensitiveContains(q)
                || server.sources.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var authCount: Int {
        state.mcpPool.servers.filter(\.hasExtractedAuth).count
    }

    var body: some View {
        heroCard
        poolCard
        syncAppsCard
    }

    // MARK: - Hero Summary & Actions

    private var heroCard: some View {
        SettingsCard {
            HStack(spacing: DS.Spacing.l) {
                statPill(value: "\(state.mcpPool.servers.count)", label: "Pooled MCPs", tint: .purple)
                statPill(value: "\(authCount)", label: "Auth Extracted", tint: .green)
                statPill(value: "\(state.mcpPool.profiles.count)", label: "Profiles", tint: .cyan)
                statPill(value: "\(state.mcpPool.enabledSyncApps.count)", label: "Apps Linked", tint: .indigo)
                Spacer()
            }

            Divider()

            HStack(spacing: DS.Spacing.s) {
                Button {
                    state.scanMCPs()
                } label: {
                    Label(state.mcpScanning ? "Scanning…" : "Scan & Import MCPs",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(state.mcpScanning)

                Button {
                    state.syncMCPs()
                } label: {
                    Label("Sync All Apps", systemImage: "bolt.horizontal.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.mcpPool.enabledSyncApps.isEmpty)

                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add MCP", systemImage: "plus")
                }

                Spacer()

                Picker("Active profile", selection: Binding(
                    get: { state.mcpPool.activeProfileID },
                    set: { state.switchProfile($0, syncImmediately: false) }
                )) {
                    ForEach(state.mcpPool.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            if let msg = state.mcpStatusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddMCPServerSheet { newEntries in
                for entry in newEntries {
                    if let idx = state.mcpPool.servers.firstIndex(where: {
                        $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
                    }) {
                        state.mcpPool.servers[idx] = entry
                    } else {
                        state.mcpPool.servers.append(entry)
                    }
                    state.mcpPool.setServer(entry.name, enabled: true, in: state.mcpPool.activeProfileID)
                }
                state.mcpPool.servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                state.mcpStatusMessage = "Added \(newEntries.count) MCP server\(newEntries.count == 1 ? "" : "s") to pool"
            }
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditorSheet(
                server: server,
                activeProfile: state.mcpPool.activeProfile,
                existingOverride: state.mcpPool.activeProfile.overrides[server.name]
            ) { updated, override in
                if let idx = state.mcpPool.servers.firstIndex(where: { $0.id == updated.id }) {
                    state.mcpPool.servers[idx] = updated
                }
                if let pIdx = state.mcpPool.profiles.firstIndex(where: { $0.id == state.mcpPool.activeProfileID }) {
                    if let override, !override.isEmpty {
                        state.mcpPool.profiles[pIdx].overrides[updated.name] = override
                    } else {
                        state.mcpPool.profiles[pIdx].overrides.removeValue(forKey: updated.name)
                    }
                }
            } onDelete: {
                state.mcpPool.servers.removeAll { $0.id == server.id }
            }
        }
    }

    private func statPill(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Unified Pool List

    private var poolCard: some View {
        SettingsCard("Unified MCP Pool (Active: \(state.mcpPool.activeProfile.name))",
                     systemImage: "square.stack.3d.up.fill") {
            HStack(spacing: DS.Spacing.s) {
                TextField("Search MCPs, commands, URLs, or apps…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Filter", selection: $filter) {
                    ForEach(ServerFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            if filteredServers.isEmpty {
                VStack(spacing: DS.Spacing.s) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(state.mcpPool.servers.isEmpty
                         ? "No MCP servers in the pool yet. Click \"Scan & Import MCPs\" to auto-detect from your apps."
                         : "No MCP servers match your filter.")
                        .dsCaption()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.l)
            } else {
                ForEach(filteredServers) { server in
                    Divider()
                    serverRow(server)
                }
            }
        }
    }

    private func serverRow(_ server: MCPServerEntry) -> some View {
        let activeProfile = state.mcpPool.activeProfile
        let isEnabled = activeProfile.includes(serverName: server.name)
        let hasOverride = activeProfile.overrides[server.name] != nil

        return HStack(alignment: .center, spacing: DS.Spacing.m) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { state.mcpPool.setServer(server.name, enabled: $0, in: activeProfile.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEnabled ? .primary : .secondary)

                    badge(server.transport.displayName, tint: server.transport == .stdio ? .indigo : .blue)

                    if server.hasExtractedAuth {
                        badge("🔑 \(server.authSummary)", tint: .green)
                    }
                    if hasOverride {
                        badge("\(activeProfile.name) override", tint: .orange)
                    }
                }

                Text(server.endpointPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !server.sources.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(server.sources, id: \.self) { src in
                            Text(src)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                                .foregroundStyle(.secondary)
                        }
                        if let proj = server.discoveredProjectPath {
                            Text("in \(URL(fileURLWithPath: proj).lastPathComponent)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: DS.Spacing.s)

            Button("Edit") {
                editingServer = server
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }

    // MARK: - Sync Mode & Connected Apps

    private var syncAppsCard: some View {
        SettingsCard("App Sync Targets", systemImage: "arrow.triangle.branch") {
            SettingsRow("Sync mode", subtitle: state.mcpPool.syncMode.subtitle) {
                Picker("Sync mode", selection: $state.mcpPool.syncMode) {
                    ForEach(MCPSyncMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: DS.Size.controlWidth)
            }

            if state.mcpPool.syncMode == .gateway {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text("Gateway mode writes a single `notcode-hub` entry (`notcode-hook mcp-gateway`) to each app. Agents can call `notcode_get_profile` and `notcode_set_profile` inside any conversation to pick the right profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(DS.Spacing.s)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }

            ForEach(MCPClientApp.allCases) { app in
                Divider()
                let summary = state.mcpScanReport?.scannedApps.first(where: { $0.app == app })
                let exists = summary?.configExists ?? FileManager.default.fileExists(atPath: app.configURL.path)
                SettingsRow(
                    app.rawValue,
                    subtitle: "\(app.configDisplayPath)" + (summary.map { " · \($0.serverCount) detected" } ?? (exists ? " · config found" : " · not found yet"))
                ) {
                    HStack(spacing: DS.Spacing.s) {
                        if exists {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Toggle(app.rawValue, isOn: Binding(
                            get: { state.mcpPool.enabledSyncApps.contains(app) },
                            set: { on in
                                if on { state.mcpPool.enabledSyncApps.insert(app) }
                                else { state.mcpPool.enabledSyncApps.remove(app) }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }

            Text("Before each sync NotCode writes a timestamped `*.notcode-mcp-backup-*` copy (owner-only) beside every config file it changes. It keeps all non-MCP settings and any MCP server that is not in the pool.")
                .dsCaption()
        }
    }
}

// MARK: - Server Inspector & Editor Sheet

private struct MCPServerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServerEntry
    let activeProfile: MCPProfile
    @State private var argsText: String
    @State private var envRows: [KVRow]
    @State private var headerRows: [KVRow]
    @State private var overrideEnvRows: [KVRow]
    @State private var overrideHeaderRows: [KVRow]
    @State private var overrideURL: String
    @State private var revealSecrets = false

    let onSave: (MCPServerEntry, MCPCredentialOverride?) -> Void
    let onDelete: () -> Void

    struct KVRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(
        server: MCPServerEntry,
        activeProfile: MCPProfile,
        existingOverride: MCPCredentialOverride?,
        onSave: @escaping (MCPServerEntry, MCPCredentialOverride?) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self._server = State(initialValue: server)
        self.activeProfile = activeProfile
        self._argsText = State(initialValue: server.args.joined(separator: " "))
        self._envRows = State(initialValue: server.env.keys.sorted().map { KVRow(key: $0, value: server.env[$0] ?? "") })
        self._headerRows = State(initialValue: server.headers.keys.sorted().map { KVRow(key: $0, value: server.headers[$0] ?? "") })
        self._overrideEnvRows = State(initialValue: (existingOverride?.env.keys.sorted() ?? []).map {
            KVRow(key: $0, value: existingOverride?.env[$0] ?? "")
        })
        self._overrideHeaderRows = State(initialValue: (existingOverride?.headers.keys.sorted() ?? []).map {
            KVRow(key: $0, value: existingOverride?.headers[$0] ?? "")
        })
        self._overrideURL = State(initialValue: existingOverride?.url ?? "")
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Text("Edit MCP Server: \(server.name)")
                    .font(.headline)
                Spacer()
                Button {
                    revealSecrets.toggle()
                } label: {
                    Label(revealSecrets ? "Hide secrets" : "Reveal secrets",
                          systemImage: revealSecrets ? "eye.slash" : "eye")
                }
                .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    SettingsCard("Connection", systemImage: "network") {
                        SettingsRow("Name") {
                            TextField("server-name", text: $server.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                        SettingsRow("Transport") {
                            Picker("Transport", selection: $server.transport) {
                                ForEach(MCPTransport.allCases) { t in
                                    Text(t.displayName).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                        }
                        if server.transport == .stdio {
                            SettingsRow("Command") {
                                TextField("npx / uvx / binary", text: Binding(
                                    get: { server.command ?? "" },
                                    set: { server.command = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                            }
                            SettingsRow("Arguments", subtitle: "Space-separated") {
                                TextField("-y @modelcontextprotocol/server", text: $argsText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                            }
                        } else {
                            SettingsRow("URL") {
                                TextField("https://...", text: Binding(
                                    get: { server.url ?? "" },
                                    set: { server.url = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                            }
                        }
                    }

                    kvCard(title: "Extracted Environment & API Keys", icon: "key.fill", rows: $envRows)
                    kvCard(title: "HTTP Auth Headers", icon: "lock.shield.fill", rows: $headerRows)

                    SettingsCard("\(activeProfile.name) Profile Overrides", systemImage: "person.badge.key.fill") {
                        Text("Optional credentials used ONLY when the '\(activeProfile.name)' profile is active (e.g. separate Personal vs Work API keys).")
                            .dsCaption()
                        if server.transport != .stdio {
                            SettingsRow("Override URL") {
                                TextField("Leave blank to use default URL", text: $overrideURL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                            }
                        }
                        kvListEditor(label: "Override Env", rows: $overrideEnvRows)
                        kvListEditor(label: "Override Headers", rows: $overrideHeaderRows)
                    }
                }
            }

            HStack {
                Button("Remove from Pool", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: 560, height: 560)
    }

    private func kvCard(title: String, icon: String, rows: Binding<[KVRow]>) -> some View {
        SettingsCard(title, systemImage: icon) {
            kvListEditor(label: title, rows: rows)
        }
    }

    private func kvListEditor(label: String, rows: Binding<[KVRow]>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(rows) { $row in
                HStack(spacing: DS.Spacing.s) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 160)
                    if revealSecrets || !MCPAuthDetector.isSensitiveKey(row.key) {
                        TextField("value", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        SecureField("secret value", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                    Button {
                        rows.wrappedValue.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("+ Add \(label.contains("Header") ? "Header" : "Variable")") {
                rows.wrappedValue.append(KVRow(key: "", value: ""))
            }
            .controlSize(.small)
        }
    }

    private func saveAndDismiss() {
        var updated = server
        updated.args = argsText.split(whereSeparator: \.isWhitespace).map(String.init)
        updated.env = Dictionary(
            envRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, new in new })
        updated.headers = Dictionary(
            headerRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, new in new })

        let ovEnv = Dictionary(
            overrideEnvRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, new in new })
        let ovHeaders = Dictionary(
            overrideHeaderRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, new in new })
        let trimmedURL = overrideURL.trimmingCharacters(in: .whitespaces)
        let override = MCPCredentialOverride(
            url: trimmedURL.isEmpty ? nil : trimmedURL,
            env: ovEnv,
            headers: ovHeaders)

        onSave(updated, override.isEmpty ? nil : override)
        dismiss()
    }
}

// MARK: - Add MCP Sheet (Form or Paste JSON)

private struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0 // 0 = Form, 1 = Paste JSON
    @State private var name = ""
    @State private var transport: MCPTransport = .http
    @State private var command = ""
    @State private var argsText = ""
    @State private var url = ""
    @State private var authHeaderKey = "Authorization"
    @State private var authHeaderValue = ""
    @State private var jsonSnippet = ""
    @State private var parseError: String?

    let onAdd: ([MCPServerEntry]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Add MCP Server to Pool")
                .font(.headline)

            Picker("Mode", selection: $mode) {
                Text("Form").tag(0)
                Text("Paste JSON").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == 0 {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    SettingsRow("Name") {
                        TextField("e.g. github, linear, supabase", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    SettingsRow("Transport") {
                        Picker("Transport", selection: $transport) {
                            ForEach(MCPTransport.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    if transport == .stdio {
                        SettingsRow("Command") {
                            TextField("npx", text: $command)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                        SettingsRow("Arguments") {
                            TextField("-y @modelcontextprotocol/server-github", text: $argsText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                    } else {
                        SettingsRow("Endpoint URL") {
                            TextField("https://mcp.example.com/mcp", text: $url)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                        SettingsRow("Auth Header (optional)") {
                            HStack(spacing: 4) {
                                TextField("Header", text: $authHeaderKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                SecureField("Bearer …", text: $authHeaderValue)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 156)
                            }
                        }
                    }
                }
            } else {
                Text("Paste any standard MCP JSON block (`{\"mcpServers\": {...}}` or a single server config):")
                    .dsCaption()
                TextEditor(text: $jsonSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }

            if let parseError {
                Text(parseError).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add to Pool") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: 480, height: 360)
    }

    private func submit() {
        if mode == 1 {
            let parsed = MCPSyncer.parsePastedSnippet(jsonSnippet)
            if parsed.isEmpty {
                parseError = "Could not parse any MCP server from that JSON."
                return
            }
            onAdd(parsed)
            dismiss()
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            parseError = "Enter a server name."
            return
        }
        var headers: [String: String] = [:]
        if !authHeaderValue.trimmingCharacters(in: .whitespaces).isEmpty {
            headers[authHeaderKey.trimmingCharacters(in: .whitespaces)] = authHeaderValue
        }
        let entry = MCPServerEntry(
            name: trimmedName,
            transport: transport,
            command: transport == .stdio ? command.trimmingCharacters(in: .whitespaces) : nil,
            args: transport == .stdio ? argsText.split(whereSeparator: \.isWhitespace).map(String.init) : [],
            url: transport != .stdio ? url.trimmingCharacters(in: .whitespaces) : nil,
            headers: headers,
            sources: ["Manual"])
        onAdd([entry])
        dismiss()
    }
}
