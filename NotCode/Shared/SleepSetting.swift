import Foundation

/// macOS's system-wide "never sleep" switch, `pmset -a disablesleep`.
///
/// Unlike a `caffeinate` assertion it holds with the lid closed and outlives
/// whatever turned it on, NotCode included. So the menu never trusts its own
/// memory of it: it reads the real value from `pmset -g` every time it opens.
enum SleepSetting {
    /// Whether `pmset -g` output reports system sleep as disabled.
    ///
    /// macOS prints a `SleepDisabled` line (`1` or `0`) once the switch has
    /// ever been set; a machine where it never was prints no line at all.
    static func isDisabled(pmsetOutput: String) -> Bool {
        for line in pmsetOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "SleepDisabled" { return fields.last == "1" }
        }
        return false
    }
}
