import Foundation

/// The fun spoken alerts are produced by macOS's own `say` voices. Recordings
/// of Apple voices aren't ours to redistribute, so instead of shipping them
/// in the repo/app we synthesize them locally on first launch.
enum SpokenSounds {
    struct Spec {
        let file: String
        let voice: String
        let text: String
    }

    static let all: [Spec] = [
        Spec(file: "claude-needs-you.aiff", voice: "Zarvox", text: "Claude needs you"),
        Spec(file: "task-done-fanfare.aiff", voice: "Good News", text: "The task is done"),
    ]

    /// Generates any missing spoken sounds into the installed sounds dir.
    /// Falls back to the default system voice when a novelty voice isn't
    /// installed. Best-effort: a failure just means the picker has one fewer
    /// option.
    static func ensureGenerated(into directory: URL = Paths.installedSounds) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for spec in all {
            let target = directory.appendingPathComponent(spec.file)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            if !runSay(["-v", spec.voice, "-o", target.path, spec.text]) {
                _ = runSay(["-o", target.path, spec.text])
            }
        }
    }

    private static func runSay(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.append("spoken sounds: say failed: \(error)")
            return false
        }
    }
}
