import Foundation

extension SleepSetting {
    enum ChangeError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Cancelled"
            case .failed(let message): return message
            }
        }
    }

    /// The live value, read from `pmset -g` (no privileges needed).
    static func current() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return isDisabled(pmsetOutput: String(decoding: data, as: UTF8.self))
    }

    /// Turns system sleep off (`disabled: true`) or back on. `pmset` needs root,
    /// so macOS shows its own administrator password prompt; NotCode never sees
    /// or stores the password. Blocks until the prompt is answered.
    static func set(disabled: Bool) throws {
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let source = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        let userCancelled = -128
        if error[NSAppleScript.errorNumber] as? Int == userCancelled { throw ChangeError.cancelled }
        throw ChangeError.failed(error[NSAppleScript.errorMessage] as? String ?? "pmset failed")
    }
}
