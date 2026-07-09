import Foundation

/// Abstracts `Task.sleep` so simulated-latency providers and retry/backoff
/// paths can be unit-tested without actually waiting. Production code uses
/// `RealSleepClock`; tests use an instant no-op implementation.
public protocol SleepClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct RealSleepClock: SleepClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
