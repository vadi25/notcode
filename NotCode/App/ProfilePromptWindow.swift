import SwiftUI
import AppKit

/// Native floating window that asks the user which MCP profile to use when an
/// agent starts working in a project that isn't bound to a profile yet.
@MainActor
final class ProfilePromptController {
    static let shared = ProfilePromptController()
    private var window: NSWindow?

    func show(for prompt: PendingProfilePrompt, state: AppState) {
        window?.close()
        let view = ProfilePromptView(prompt: prompt) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        .environmentObject(state)

        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: controller)
        win.title = "Choose MCP Profile"
        win.styleMask = [.titled, .closable]
        win.level = .floating
        win.setContentSize(NSSize(width: 440, height: 340))
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ProfilePromptView: View {
    @EnvironmentObject private var state: AppState
    let prompt: PendingProfilePrompt
    let dismiss: () -> Void

    @State private var rememberForProject = true
    @State private var syncImmediately = true

    private var projectName: String {
        URL(fileURLWithPath: prompt.projectPath).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.m) {
                TintedIcon(systemImage: "person.crop.rectangle.stack.fill", tint: .cyan, size: DS.Size.paneIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Which MCP profile for \(projectName)?")
                        .font(.headline)
                    Text("\(prompt.agent) is working in \(prompt.projectPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ScrollView {
                VStack(spacing: DS.Spacing.s) {
                    ForEach(state.mcpPool.profiles) { profile in
                        Button {
                            if rememberForProject {
                                state.bindProject(prompt.projectPath, to: profile.id, activateAndSync: syncImmediately)
                            } else {
                                state.switchProfile(profile.id, syncImmediately: syncImmediately)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: DS.Spacing.m) {
                                TintedIcon(systemImage: profile.icon, tint: ProfileColor.color(named: profile.colorName), size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(profile.name)
                                            .font(.subheadline.weight(.semibold))
                                        if profile.id == state.mcpPool.activeProfileID {
                                            Text("ACTIVE")
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    let count = state.mcpPool.resolvedServers(for: profile).count
                                    let overrides = profile.overrides.count
                                    Text("\(count) MCP\(count == 1 ? "" : "s")" + (overrides > 0 ? " · \(overrides) custom auth" : ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(DS.Spacing.m)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Toggle("Remember this profile for \(projectName)", isOn: $rememberForProject)
                    .font(.caption)
                Toggle("Sync connected AI apps immediately", isOn: $syncImmediately)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Keep current (\(state.mcpPool.activeProfile.name))") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440, height: 340)
    }
}

enum ProfileColor {
    static let allNames = ["indigo", "teal", "orange", "purple", "pink", "green", "blue"]

    static func color(named name: String) -> Color {
        switch name {
        case "teal": return .teal
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "green": return .green
        case "blue": return .blue
        default: return .indigo
        }
    }
}
