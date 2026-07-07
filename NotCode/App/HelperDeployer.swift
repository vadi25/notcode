import Foundation

/// Copies the hook helper and bundled sounds to a stable path in Application
/// Support on every app launch. Hooks point there, so notifications keep
/// working if the app is moved, updated, or not running.
enum HelperDeployer {
    static func deploy() {
        Paths.ensureAppSupportExists()
        let fm = FileManager.default

        if let source = Bundle.main.url(forAuxiliaryExecutable: "notcode-hook") {
            do {
                if fm.fileExists(atPath: Paths.installedHelper.path) {
                    try fm.removeItem(at: Paths.installedHelper)
                }
                try fm.copyItem(at: source, to: Paths.installedHelper)
                try fm.setAttributes([.posixPermissions: 0o755],
                                     ofItemAtPath: Paths.installedHelper.path)
            } catch {
                Log.append("deploy: helper copy failed: \(error)")
            }
        } else {
            Log.append("deploy: notcode-hook not found in app bundle")
        }

        if let sounds = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
           fm.fileExists(atPath: sounds.path) {
            do {
                if fm.fileExists(atPath: Paths.installedSounds.path) {
                    try fm.removeItem(at: Paths.installedSounds)
                }
                try fm.copyItem(at: sounds, to: Paths.installedSounds)
            } catch {
                Log.append("deploy: sounds copy failed: \(error)")
            }
        }
    }

    /// Names of the sounds shipped with the app, for the settings picker.
    static func bundledSoundNames() -> [String] {
        let dir = Bundle.main.resourceURL?.appendingPathComponent("Sounds")
        guard let dir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }
}
