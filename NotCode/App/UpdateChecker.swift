import Foundation
import AppKit

/// Lightweight self-updater: compares the running version against the latest
/// GitHub release; on request downloads the DMG and swaps the app via a
/// detached shell script (same steps as install.sh). Sparkle can replace this
/// once builds are notarized.
enum UpdateChecker {
    static let repo = "vadi25/notcode"
    static let releasesPage = URL(string: "https://github.com/vadi25/notcode/releases/latest")!
    private static let dmgURL =
        URL(string: "https://github.com/vadi25/notcode/releases/latest/download/NotCode.dmg")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Returns the newer remote version string, or nil if up to date.
    static func checkForUpdate() async -> String? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String
        else { return nil }
        return VersionCompare.isNewer(tag, than: currentVersion) ? tag : nil
    }

    /// Only self-swap when running from /Applications; a dev build launched
    /// from a build folder just opens the releases page instead.
    static var canSelfUpdate: Bool {
        Bundle.main.bundlePath == "/Applications/NotCode.app"
    }

    /// Downloads the latest DMG, then hands off to a detached script that
    /// waits for this process to exit, swaps the app, and relaunches it.
    static func downloadAndInstall() async throws {
        let (tmpDMG, response) = try await URLSession.shared.download(from: dmgURL)
        if let status = (response as? HTTPURLResponse)?.statusCode,
           !(200..<300).contains(status) {
            throw NSError(domain: "NotCode", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "download failed (HTTP \(status))"
            ])
        }
        let dmg = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotCode-update.dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: tmpDMG, to: dmg)

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("notcode-update.sh")
        try updateScript(dmgPath: dmg.path).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/bash", script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        Log.append("update: handing off to swap script, quitting")
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func updateScript(dmgPath: String) -> String {
        """
        #!/bin/bash
        set -e
        # Wait for NotCode to fully quit.
        for _ in $(seq 1 20); do pgrep -x NotCode >/dev/null || break; sleep 0.5; done
        MOUNT=$(hdiutil attach '\(dmgPath)' -nobrowse -readonly | awk -F'\\t' '/\\/Volumes\\//{print $NF; exit}')
        # Never remove the installed app until the replacement is confirmed
        # present — a bad download must not leave the user with nothing.
        if [ ! -d "$MOUNT/NotCode.app" ]; then
            hdiutil detach "$MOUNT" -quiet || true
            rm -f '\(dmgPath)'
            open /Applications/NotCode.app
            exit 1
        fi
        rm -rf /Applications/NotCode.app
        cp -R "$MOUNT/NotCode.app" /Applications/
        hdiutil detach "$MOUNT" -quiet || true
        xattr -dr com.apple.quarantine /Applications/NotCode.app 2>/dev/null || true
        rm -f '\(dmgPath)'
        open /Applications/NotCode.app
        """
    }
}
