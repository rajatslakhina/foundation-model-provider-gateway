import XCTest
@testable import ProviderGatewayKit

/// The two production implementations behind the seams every other test replaces.
///
/// `InstantSleepClock` and `ManualClock` exist so nothing in this suite waits on real
/// time, which is right — but it leaves the real implementations untested, and those
/// are what ships. They are small enough to pin directly.
final class ProductionSeamTests: XCTestCase {
    func testTheRealSleepClockActuallySleeps() async throws {
        let clock = RealSleepClock()
        let started = SystemMonotonicClock().now()
        try await clock.sleep(for: .milliseconds(20))
        let elapsed = SystemMonotonicClock().now() - started

        // A generous floor: the assertion is that time passed, not how much. Anything
        // tighter would be a test of the scheduler's punctuality rather than of this type.
        XCTAssertGreaterThan(elapsed, 0.005)
    }

    func testTheRealSleepClockPropagatesCancellation() async {
        let task = Task {
            try await RealSleepClock().sleep(for: .seconds(30))
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("a cancelled sleep should throw rather than complete")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// The reason this clock exists rather than `Date()`: it must never go backwards.
    func testTheSystemMonotonicClockNeverGoesBackwards() {
        let clock = SystemMonotonicClock()
        var previous = clock.now()
        for _ in 0..<200 {
            let current = clock.now()
            XCTAssertGreaterThanOrEqual(current, previous)
            previous = current
        }
    }

    func testTheSystemMonotonicClockReportsSecondsRatherThanNanoseconds() {
        let first = SystemMonotonicClock().now()
        let second = SystemMonotonicClock().now()
        // Two back-to-back reads are microseconds apart, so a value scaled to seconds
        // differs by far less than one. A nanosecond-scaled value would not.
        XCTAssertLessThan(second - first, 1)
        XCTAssertGreaterThan(first, 0)
    }
}
