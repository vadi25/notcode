import Foundation
import AVFoundation

/// Resolves SoundChoice values to files and plays them. Works both inside the
/// app bundle and from the bare helper binary in Application Support (the app
/// copies the bundled sounds next to the helper on every launch).
enum SoundPlayer {
    static let systemSoundsDir = URL(fileURLWithPath: "/System/Library/Sounds")

    static func url(for choice: SoundChoice) -> URL? {
        switch choice.kind {
        case .none:
            return nil
        case .file:
            return URL(fileURLWithPath: choice.value)
        case .system:
            return systemSoundsDir.appendingPathComponent(choice.value + ".aiff")
        case .bundled:
            let name = (choice.value as NSString).deletingPathExtension
            let ext = (choice.value as NSString).pathExtension
            if let bundled = Bundle.main.url(forResource: name, withExtension: ext,
                                             subdirectory: "Sounds") {
                return bundled
            }
            let installed = Paths.installedSounds.appendingPathComponent(choice.value)
            return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
        }
    }

    static func systemSoundNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: systemSoundsDir.path)) ?? []
        return names.filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    private static var activePlayer: AVAudioPlayer?

    /// Plays the sound. If `blocking` (hook helper), waits for playback to end
    /// so the process doesn't exit mid-sound; capped at 6 seconds.
    @discardableResult
    static func play(_ choice: SoundChoice, volume: Double, blocking: Bool = false) -> Bool {
        guard let url = url(for: choice),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return false }

        player.volume = Float(max(0, min(1, volume)))
        activePlayer = player
        guard player.play() else { return false }

        if blocking {
            let deadline = Date().addingTimeInterval(6)
            while player.isPlaying && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        return true
    }
}
