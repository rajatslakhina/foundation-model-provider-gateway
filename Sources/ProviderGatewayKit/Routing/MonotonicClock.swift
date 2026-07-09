import Foundation

/// A monotonic time source abstracted behind a protocol so
/// `CircuitBreaker`'s reset-timeout logic can be tested deterministically —
/// production code advances with wall-clock time; tests advance a fake
/// clock manually and never sleep.
///
/// This is the same reason `SleepClock` exists as a separate seam: without
/// it, every circuit-breaker or backoff test would either be flaky (racing
/// real timers) or slow (waiting out real reset windows).
public protocol MonotonicClock: Sendable {
    /// Seconds since an arbitrary, implementation-defined epoch. Only
    /// differences between two calls are meaningful.
    func now() -> Double
}

/// Production clock backed by `DispatchTime`, which is guaranteed
/// monotonic (unlike `Date`, which can jump on wall-clock changes).
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
