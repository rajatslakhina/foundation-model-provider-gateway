import Foundation

/// Standard three-state circuit breaker (closed → open → half-open →
/// closed/open) guarding a single provider.
///
/// Why this exists: without it, a provider that starts failing (rate
/// limited, backend outage) would be retried on every single request
/// forever, adding latency to every call while it stays down. Tripping the
/// breaker after a run of consecutive failures lets the router skip a
/// known-bad provider immediately and go straight to a fallback, then
/// periodically probe the failed provider again instead of either hammering
/// it or abandoning it permanently.
///
/// Isolated as its own `actor` (one instance per provider, owned by
/// `ProviderRouter`) so its state transitions are race-free without the
/// router needing its own locking around breaker bookkeeping.
public actor CircuitBreaker {
    public enum State: Sendable, Equatable {
        case closed
        case open(until: Double)
        case halfOpen
    }

    private var state: State = .closed
    private var consecutiveFailures = 0

    private let failureThreshold: Int
    private let resetTimeout: Double
    private let clock: any MonotonicClock

    /// - Parameters:
    ///   - failureThreshold: consecutive failures required to trip from
    ///     closed to open. Must be positive.
    ///   - resetTimeout: seconds to wait after tripping before allowing a
    ///     single half-open probe request through.
    ///   - clock: injected so tests can advance time deterministically
    ///     instead of sleeping through real reset windows.
    public init(
        failureThreshold: Int = 3,
        resetTimeout: Double = 30,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) {
        precondition(failureThreshold > 0, "failureThreshold must be positive")
        precondition(resetTimeout >= 0, "resetTimeout must be non-negative")
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.clock = clock
    }

    /// Whether a request should be allowed through right now. Calling this
    /// also performs the open → half-open transition if the reset timeout
    /// has elapsed, so callers don't need to poll separately.
    public func allowsRequest() -> Bool {
        switch state {
        case .closed, .halfOpen:
            return true
        case .open(let until):
            if clock.now() >= until {
                state = .halfOpen
                return true
            }
            return false
        }
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        state = .closed
    }

    public func recordFailure() {
        switch state {
        case .halfOpen:
            // The probe request also failed — go straight back to open
            // rather than requiring the full threshold again.
            trip()
        case .closed:
            consecutiveFailures += 1
            if consecutiveFailures >= failureThreshold {
                trip()
            }
        case .open:
            // Shouldn't normally receive a result while open (allowsRequest
            // would have blocked it), but stay defensive rather than
            // asserting on a state a caller could reach via a race.
            trip()
        }
    }

    public var currentState: State { state }

    private func trip() {
        consecutiveFailures = 0
        state = .open(until: clock.now() + resetTimeout)
    }
}
