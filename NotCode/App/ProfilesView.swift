import SwiftUI
import AppKit

// MARK: - Profiles & Project Bindings Pane

struct ProfilesSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var showingNewProfileSheet = false
    @State private var editingProfile: MCPProfile?

    var body: some View {
        profilesCard
        projectBindingsCard
    }

    // MARK: - Profiles List

    private var profilesCard: some View {
        SettingsCard("MCP Profiles", systemImage: "person.crop.rectangle.stack.fill") {
            Text("Keep separate sets of MCPs and API credentials for Personal, Work, or Private accounts. Switching a profile updates all linked AI apps.")
                .dsCaption()

            ForEach(state.mcpPool.profiles) { profile in
                Divider()
                profileRow(profile)
            }

            Divider()

            HStack {
                Button {
                    showingNewProfileSheet = true
                } label: {
                    Label("New Profile…", systemImage: "plus")
                }
                Spacer()
                Button("Test Profile Picker Popup") {
                    ProfilePromptController.shared.show(
                        for: PendingProfilePrompt(projectPath: Paths.home.appendingPathComponent("my-project").path,
                                                  agent: "Claude Code"),
                        state: state)
                }
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $showingNewProfileSheet) {
            ProfileEditorSheet(
                profile: MCPProfile(name: "", icon: "person.fill", colorName: "purple"),
                allServers: state.mcpPool.servers,
                isNew: true
            ) { created in
                state.mcpPool.profiles.append(created)
            } onDelete: {}
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(
                profile: profile,
                allServers: state.mcpPool.servers,
                isNew: false
            ) { updated in
                if let idx = state.mcpPool.profiles.firstIndex(where: { $0.id == updated.id }) {
                    state.mcpPool.profiles[idx] = updated
                }
            } onDelete: {
                guard state.mcpPool.profiles.count > 1 else { return }
                state.mcpPool.profiles.removeAll { $0.id == profile.id }
                if state.mcpPool.activeProfileID == profile.id,
                   let first = state.mcpPool.profiles.first {
                    state.mcpPool.activeProfileID = first.id
                }
                state.mcpPool.projectBindings.removeAll { $0.profileID == profile.id }
            }
        }
    }

    private func profileRow(_ profile: MCPProfile) -> some View {
        let isActive = profile.id == state.mcpPool.activeProfileID
        let resolvedCount = state.mcpPool.resolvedServers(for: profile).count
        let overrideCount = profile.overrides.count

        return HStack(spacing: DS.Spacing.m) {
            TintedIcon(systemImage: profile.icon,
                       tint: ProfileColor.color(named: profile.colorName),
                       size: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                            .foregroundStyle(.green)
                    }
                    if profile.includeAllByDefault {
                        Text("ALL MCPS")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(resolvedCount) MCP\(resolvedCount == 1 ? "" : "s")" + (overrideCount > 0 ? " · \(overrideCount) credential override\(overrideCount == 1 ? "" : "s")" : ""))
                    .dsCaption()
            }

            Spacer()

            if !isActive {
                Button("Activate & Sync") {
                    state.switchProfile(profile.id, syncImmediately: true)
                }
                .controlSize(.small)
            }

            Button("Edit") {
                editingProfile = profile
            }
            .controlSize(.small)
        }
    }

    // MARK: - Project Bindings

    private var projectBindingsCard: some View {
        SettingsCard("Per-Project Profile Mapping", systemImage: "folder.fill.badge.person.crop") {
            SettingsRow(
                "Ask which profile to use for new projects",
                subtitle: "When an agent works in an unbound folder, NotCode prompts you to pick Personal, Work, etc. — and tells MCP-connected agents to ask too."
            ) {
                Toggle("Ask which profile to use for new projects",
                       isOn: $state.mcpPool.askProfileForNewProjects)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if state.mcpPool.projectBindings.isEmpty {
                Divider()
                Text("No project folders bound yet. Add a folder below to automatically associate it with Personal or Work.")
                    .dsCaption()
            } else {
                ForEach(state.mcpPool.projectBindings) { binding in
                    Divider()
                    HStack(spacing: DS.Spacing.m) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(binding.projectName)
                                .font(.subheadline.weight(.medium))
                            Text(binding.projectPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Profile", selection: Binding(
                            get: { binding.profileID },
                            set: { newID in state.mcpPool.bindProject(binding.projectPath, to: newID) }
                        )) {
                            ForEach(state.mcpPool.profiles) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        Button {
                            state.mcpPool.unbindProject(id: binding.id)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            Button {
                chooseProjectFolder()
            } label: {
                Label("Bind Project Folder…", systemImage: "folder.badge.plus")
            }
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Bind Folder"
        if panel.runModal() == .OK, let url = panel.url {
            state.mcpPool.bindProject(url.path, to: state.mcpPool.activeProfileID)
        }
    }
}

// MARK: - Profile Editor Sheet

private struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: MCPProfile
    let allServers: [MCPServerEntry]
    let isNew: Bool
    let onSave: (MCPProfile) -> Void
    let onDelete: () -> Void

    private let iconChoices = [
        "sparkles", "house.fill", "briefcase.fill", "lock.fill",
        "key.fill", "terminal.fill", "person.fill", "building.2.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(isNew ? "New Profile" : "Edit Profile: \(profile.name)")
                .font(.headline)

            SettingsCard {
                SettingsRow("Profile name") {
                    TextField("e.g. Work, Personal, Client X", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }

                SettingsRow("Icon") {
                    HStack(spacing: 6) {
                        ForEach(iconChoices, id: \.self) { sym in
                            Button {
                                profile.icon = sym
                            } label: {
                                Image(systemName: sym)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(profile.icon == sym ? Color.accentColor.opacity(0.2) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                SettingsRow("Color") {
                    HStack(spacing: 8) {
                        ForEach(ProfileColor.allNames, id: \.self) { name in
                            Circle()
                                .fill(ProfileColor.color(named: name))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(.white, lineWidth: profile.colorName == name ? 2 : 0)
                                )
                                .onTapGesture { profile.colorName = name }
                        }
                    }
                }

                SettingsRow("Include all pooled MCPs automatically") {
                    Toggle("", isOn: $profile.includeAllByDefault)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            if !profile.includeAllByDefault {
                SettingsCard("Enabled MCPs in this Profile") {
                    if allServers.isEmpty {
                        Text("Scan or add MCPs in the MCP Hub tab first.")
                            .dsCaption()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                ForEach(allServers) { server in
                                    Toggle(isOn: Binding(
                                        get: { profile.enabledServerNames.contains(server.name) },
                                        set: { on in
                                            if on { profile.enabledServerNames.insert(server.name) }
                                            else { profile.enabledServerNames.remove(server.name) }
                                        }
                                    )) {
                                        HStack {
                                            Text(server.name).font(.subheadline)
                                            if profile.overrides[server.name] != nil {
                                                Text("(custom auth)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }

            Spacer()

            HStack {
                if !isNew {
                    Button("Delete Profile", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Create Profile" : "Save") {
                    guard !profile.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onSave(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: 500, height: 480)
    }
}
