import Foundation
@testable import ProviderGatewayKit

/// A fake `MonotonicClock` that only advances when a test tells it to, so
/// `CircuitBreaker` reset-timeout behavior can be tested deterministically
/// and instantly instead of via real sleeps.
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double

    init(startingAt: Double = 0) {
        self.current = startingAt
    }

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: Double) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}
