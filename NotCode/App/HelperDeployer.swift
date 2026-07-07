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

        for module in AgentRegistry.all { module.repairAfterLaunch() }

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
        SpokenSounds.ensureGenerated()
    }

    /// Names of NotCode's own sounds for the settings picker: shipped with the
    /// app plus the spoken ones generated locally at deploy time.
    static func bundledSoundNames() -> [String] {
        var names = Set<String>()
        for dir in [Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
                    Paths.installedSounds] {
            guard let dir,
                  let found = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            names.formUnion(found.filter { !$0.hasPrefix(".") })
        }
        return names.sorted()
    }
}
