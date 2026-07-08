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

        // The fixed `latest/download` URL could serve an older build (rollback
        // or stale CDN); never replace the installed app with one that isn't
        // strictly newer.
        do {
            try verifyDownloadedIsNewer(dmg: dmg)
        } catch {
            try? FileManager.default.removeItem(at: dmg)
            throw error
        }

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

    /// Mounts the downloaded DMG and throws unless the app inside reports a
    /// version strictly newer than the running one. Always detaches the mount.
    private static func verifyDownloadedIsNewer(dmg: URL) throws {
        let mount = try attachDMG(dmg)
        defer { detachDMG(mount) }
        let plist = URL(fileURLWithPath: mount)
            .appendingPathComponent("NotCode.app/Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let version = info["CFBundleShortVersionString"] as? String
        else {
            throw NSError(domain: "NotCode", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "downloaded app has no readable version"
            ])
        }
        guard VersionCompare.isNewer(version, than: currentVersion) else {
            throw NSError(domain: "NotCode", code: 5, userInfo: [
                NSLocalizedDescriptionKey:
                    "downloaded version \(version) is not newer than \(currentVersion)"
            ])
        }
    }

    private static func attachDMG(_ dmg: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmg.path, "-nobrowse", "-readonly"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let mount = output.split(separator: "\n")
                  .compactMap({ $0.split(separator: "\t").last })
                  .map({ $0.trimmingCharacters(in: .whitespaces) })
                  .first(where: { $0.hasPrefix("/Volumes/") })
        else {
            throw NSError(domain: "NotCode", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "downloaded DMG could not be mounted"
            ])
        }
        return mount
    }

    private static func detachDMG(_ mount: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount, "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
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
