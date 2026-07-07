import Foundation
import CoreGraphics

enum IdleTime {
    /// Seconds since the user last touched keyboard or mouse.
    static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType == ~0; imported C enums accept arbitrary raw values.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyInput)
    }
}
