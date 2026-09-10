import Foundation

@main
struct LiveViewTimingTests {
    static func main() {
        func check(_ elapsed: Double, expected: Double) {
            let actual = LiveViewTiming.remainingDelay(startedAt: 10, now: 10 + elapsed)
            precondition(abs(actual - expected) < 0.000001, "Unexpected delay: \(actual)")
        }
        precondition(LiveViewTiming.framesPerSecond == 30)
        check(0, expected: 1.0 / 30)
        check(0.010, expected: 1.0 / 30 - 0.010)
        check(1.0 / 30, expected: 0)
        check(0.060, expected: 0)
        // Slow cameras must not acquire an extra frame-budget delay after their transfer.
        check(1, expected: 0)
        print("Live view timing tests passed")
    }
}
