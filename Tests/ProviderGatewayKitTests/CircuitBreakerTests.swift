import XCTest
@testable import ProviderGatewayKit

final class CircuitBreakerTests: XCTestCase {
    func testClosedByDefaultAllowsRequests() async {
        let breaker = CircuitBreaker(failureThreshold: 3, resetTimeout: 30, clock: ManualClock())
        let allowed = await breaker.allowsRequest()
        XCTAssertTrue(allowed)
        let state = await breaker.currentState
        XCTAssertEqual(state, .closed)
    }

    func testTripsAfterConsecutiveFailuresReachThreshold() async {
        let breaker = CircuitBreaker(failureThreshold: 3, resetTimeout: 30, clock: ManualClock())
        await breaker.recordFailure()
        await breaker.recordFailure()
        var state = await breaker.currentState
        XCTAssertEqual(state, .closed, "should stay closed below threshold")

        await breaker.recordFailure()
        state = await breaker.currentState
        guard case .open = state else {
            return XCTFail("expected open state after reaching failure threshold, got \(state)")
        }
    }

    func testSuccessResetsFailureCount() async {
        let breaker = CircuitBreaker(failureThreshold: 3, resetTimeout: 30, clock: ManualClock())
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordSuccess()
        await breaker.recordFailure()
        await breaker.recordFailure()
        // Two more failures after a reset should not be enough to trip a
        // threshold-of-3 breaker.
        let state = await breaker.currentState
        XCTAssertEqual(state, .closed)
    }

    func testOpenBreakerBlocksRequestsUntilResetTimeoutElapses() async {
        let clock = ManualClock(startingAt: 100)
        let breaker = CircuitBreaker(failureThreshold: 1, resetTimeout: 10, clock: clock)
        await breaker.recordFailure()

        var allowed = await breaker.allowsRequest()
        XCTAssertFalse(allowed, "should block immediately after tripping")

        clock.advance(by: 5)
        allowed = await breaker.allowsRequest()
        XCTAssertFalse(allowed, "should still block before resetTimeout elapses")

        clock.advance(by: 5.001)
        allowed = await breaker.allowsRequest()
        XCTAssertTrue(allowed, "should allow exactly one probe once resetTimeout has elapsed")
        let state = await breaker.currentState
        XCTAssertEqual(state, .halfOpen)
    }

    func testFailedHalfOpenProbeReopensImmediately() async {
        let clock = ManualClock(startingAt: 0)
        let breaker = CircuitBreaker(failureThreshold: 1, resetTimeout: 10, clock: clock)
        await breaker.recordFailure()
        clock.advance(by: 10.001)
        _ = await breaker.allowsRequest() // transitions to halfOpen
        await breaker.recordFailure() // the probe itself failed

        let allowedImmediatelyAfter = await breaker.allowsRequest()
        XCTAssertFalse(allowedImmediatelyAfter, "a failed half-open probe should reopen the circuit, not require the full threshold again")
    }

    func testSuccessfulHalfOpenProbeCloses() async {
        let clock = ManualClock(startingAt: 0)
        let breaker = CircuitBreaker(failureThreshold: 1, resetTimeout: 10, clock: clock)
        await breaker.recordFailure()
        clock.advance(by: 10.001)
        _ = await breaker.allowsRequest() // transitions to halfOpen
        await breaker.recordSuccess()

        let state = await breaker.currentState
        XCTAssertEqual(state, .closed)
    }

    /// A failure arriving while the circuit is already open.
    ///
    /// `allowsRequest()` would normally have blocked the call that produced it, so this
    /// is the race the breaker was written to survive: two attempts admitted before the
    /// circuit tripped, the second reporting back after it did. The breaker re-trips,
    /// which pushes the reset deadline out rather than leaving a stale one in place.
    func testAFailureArrivingWhileOpenExtendsTheResetWindow() async {
        let clock = ManualClock()
        let breaker = CircuitBreaker(failureThreshold: 1, resetTimeout: 30, clock: clock)

        await breaker.recordFailure()
        let openedAt = await breaker.currentState
        XCTAssertEqual(openedAt, .open(until: 30))

        clock.advance(by: 10)
        await breaker.recordFailure()

        let extended = await breaker.currentState
        XCTAssertEqual(extended, .open(until: 40), "the late failure should push the deadline out")

        let allowedBefore = await breaker.allowsRequest()
        XCTAssertFalse(allowedBefore, "still inside the extended window")

        clock.advance(by: 30)
        let allowedAfter = await breaker.allowsRequest()
        XCTAssertTrue(allowedAfter, "the extended window has now elapsed")
    }
}
