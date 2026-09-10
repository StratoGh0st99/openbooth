import Foundation

/// Shared target for USB live view and the built-in cameras.
enum LiveViewTiming {
    static let framesPerSecond = 30
    static let interval = 1.0 / Double(framesPerSecond)

    /// Count acquisition and processing time toward the frame budget. Never catch up with a burst.
    static func remainingDelay(startedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, interval - max(0, now - startedAt))
    }
}
