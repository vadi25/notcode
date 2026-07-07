import Foundation

/// Central filesystem locations shared by the app and the hook helper.
enum Paths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/NotCode", isDirectory: true)
    }

    static var config: URL { appSupport.appendingPathComponent("config.json") }
    static var state: URL { appSupport.appendingPathComponent("state.json") }
    static var installedHelper: URL { appSupport.appendingPathComponent("notcode-hook") }
    static var installedSounds: URL { appSupport.appendingPathComponent("Sounds", isDirectory: true) }

    static var logsDir: URL {
        home.appendingPathComponent("Library/Logs/NotCode", isDirectory: true)
    }
    static var logFile: URL { logsDir.appendingPathComponent("notcode.log") }

    static var claudeSettings: URL {
        home.appendingPathComponent(".claude/settings.json")
    }
    static var codexConfig: URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    static func ensureAppSupportExists() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }
}
