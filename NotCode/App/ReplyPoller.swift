import Foundation

/// Polls Kapso for inbound WhatsApp messages and routes them back into agent
/// sessions ("reply to keep prompting"). Runs only while the menu bar app is
/// open: hooks fire without the app, but replies need this poller.
@MainActor
final class ReplyPoller: ObservableObject {
    /// Project name of the resume currently running, for the menu bar.
    @Published private(set) var activeRun: String?

    private var timer: Timer?
    private var config = NotCodeConfig()
    private var lastPoll: Date?
    private var lastInboundActivity: Date?   // updated each time a message is processed
    private var busySessions: Set<String> = []

    /// nonisolated so non-main-actor owners (AppState) can create it; all
    /// mutable state is still only touched on the main actor.
    nonisolated init() {}

    // Within fastWindow of the last outbound WhatsApp OR the last inbound
    // message we treat the conversation as "active" and clamp the poll
    // interval to at most 15 s so replies feel snappy.  Outside that window
    // the user-chosen cadence applies (saves battery while idle).
    static let fastWindow: TimeInterval = 5 * 60

    func reconfigure(_ config: NotCodeConfig) {
        self.config = config
        let shouldRun = config.replyLoopEnabled && config.whatsAppEnabled
            && config.hasKapsoCredentials && !config.paused
        if shouldRun, timer == nil {
            // Only messages sent after enabling count.
            lastPoll = Date()
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Log.append("reply loop: polling started")
        } else if !shouldRun, timer != nil {
            timer?.invalidate()
            timer = nil
            Log.append("reply loop: polling stopped")
        }
    }

    private func tick() {
        let now = Date()
        // "Active" = within fastWindow of either the last outbound WhatsApp or
        // the last inbound message (live conversation).  Active window clamps
        // to ≤ 15 s so replies feel snappy; outside it the user's chosen
        // cadence applies.  No upper cutoff; idle but enabled always listens.
        let state = StateStore.load()
        let sinceOutbound = state.lastOutboundWhatsApp
            .map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let sinceInbound = lastInboundActivity
            .map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let active = sinceOutbound < Self.fastWindow || sinceInbound < Self.fastWindow
        let effective = TimeInterval(active ? min(config.pollIntervalSeconds, 15) : config.pollIntervalSeconds)
        if let lastPoll, now.timeIntervalSince(lastPoll) < effective { return }
        poll()
    }

    private func poll() {
        let since = lastPoll ?? Date()
        let attempted = Date()
        let config = self.config
        Task.detached(priority: .utility) { [weak self] in
            let client = KapsoClient(apiKey: config.kapsoAPIKey,
                                     phoneNumberID: config.phoneNumberID)
            // Small overlap so a message landing mid-poll isn't missed; the
            // processed-id set deduplicates.
            switch client.listInboundMessages(since: since.addingTimeInterval(-30)) {
            case .failure(let error):
                // Keep `since` where it was: a reply sent during an outage
                // must still be picked up by the next successful poll.
                Log.append("reply loop: poll failed (\(error))")
                return
            case .success(let messages):
                await MainActor.run { [weak self] in self?.lastPoll = attempted }

                let state = StateStore.load()
                for message in messages {
                    guard !state.processedMessageIDs.contains(message.id),
                          KapsoClient.phoneMatches(message.from, config.recipientPhone)
                    else { continue }
                    StateStore.markProcessed(message.id)
                    StateStore.recordInboundMessage()
                    await MainActor.run { [weak self] in self?.lastInboundActivity = Date() }
                    Log.append("reply loop: inbound \(message.id)")
                    await self?.handle(message.text, client: client, config: config)
                }
            }
        }
    }

    private func handle(_ text: String, client: KapsoClient, config: NotCodeConfig) {
        let sessions = StateStore.load().sessions
        let send = { (reply: String) in
            Task.detached(priority: .utility) {
                _ = client.sendText(reply, to: config.recipientPhone)
                StateStore.recordWhatsAppSent()   // keep the fast window open
            }
        }

        switch ReplyRouter.route(text: text, sessions: sessions) {
        case .help:
            send(ReplyRouter.helpText(sessions: sessions))
        case .noSessions:
            send("🤖 No agent sessions to reply to right now. Start one and I'll route your next message.")
        case .notFound(let prefix):
            send(ReplyRouter.notFoundText(prefix: prefix, sessions: sessions))
        case .session(let id, let prompt):
            guard let info = sessions[id] else { return }
            let module = AgentRegistry.byName(info.agent)
            let project = info.projectName ?? "unknown"
            guard !busySessions.contains(id) else {
                send("⏳ Still working on your last message for *\(project)*. Send it again when I confirm.")
                return
            }
            guard let module else {
                send("⚠️ Unknown agent for *\(project)*.")
                return
            }
            if case .unavailable(let reason) = module.resumeAvailability() {
                send("⚠️ Can't reply to \(info.agent) sessions: \(reason).")
                return
            }
            guard let command = module.resumeCommand(sessionID: id, prompt: prompt) else {
                send("⚠️ \(info.agent) sessions can't be continued remotely yet.")
                return
            }
            busySessions.insert(id)
            activeRun = project
            if config.replyConfirmationsEnabled {
                send("▶️ Sent to \(info.agent) in *\(project)*. I'll confirm when it's done.")
            }
            runResume(command: command, module: module, sessionID: id,
                      info: info, client: client, config: config)
        }
    }

    private func runResume(command: String, module: AgentModule, sessionID: String,
                           info: SessionInfo, client: KapsoClient, config: NotCodeConfig) {
        let project = info.projectName ?? "unknown"
        Task.detached(priority: .utility) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", command]
            if let cwd = info.cwd {
                // The hook payload controls this path; only resume inside a
                // real absolute directory, never somewhere unexpected.
                var isDirectory: ObjCBool = false
                guard cwd.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    Log.append("reply loop: resume aborted, invalid cwd for \(project)")
                    _ = client.sendText(
                        "⚠️ Can't resume \(info.agent) in *\(project)*: its working directory is missing.",
                        to: config.recipientPhone)
                    StateStore.recordWhatsAppSent()
                    await MainActor.run { [weak self] in
                        self?.busySessions.remove(sessionID)
                        self?.activeRun = nil
                    }
                    return
                }
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            // The resumed run's own hooks must not double-notify; the poller
            // reports the outcome itself.
            var env = ProcessInfo.processInfo.environment
            env["NOTCODE_REMOTE_RUN"] = "1"
            process.environment = env
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            var reply: String
            do {
                try process.run()
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let result = module.parseResumeOutput(stdout: output)
                    if let newID = result.newSessionID {
                        StateStore.rebindSession(from: sessionID, to: newID)
                    }
                    reply = "✅ Done in *\(project)*"
                    if config.replyExcerptEnabled, let excerpt = result.excerpt,
                       !excerpt.isEmpty {
                        reply += ":\n\(String(excerpt.prefix(300)))"
                    }
                } else {
                    reply = "⚠️ The \(info.agent) run in *\(project)* exited with an error. Check the Mac."
                }
            } catch {
                reply = "⚠️ Couldn't start \(info.agent) for *\(project)*: \(error.localizedDescription)"
            }
            Log.append("reply loop: resume finished for \(project)")
            // ✅ success confirmations are optional; ⚠️ error alerts always send.
            let suppress = reply.hasPrefix("✅") && !config.replyConfirmationsEnabled
            if !suppress {
                _ = client.sendText(reply, to: config.recipientPhone)
                StateStore.recordWhatsAppSent()
            }
            await MainActor.run { [weak self] in
                self?.busySessions.remove(sessionID)
                self?.activeRun = nil
            }
        }
    }
}
