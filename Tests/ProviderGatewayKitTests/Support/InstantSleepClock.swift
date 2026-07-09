import Foundation
@testable import ProviderGatewayKit

/// A `SleepClock` that never actually sleeps, so tests exercising the
/// simulated providers' "latency" paths run instantly instead of taking
/// real wall-clock milliseconds per call.
struct InstantSleepClock: SleepClock {
    func sleep(for duration: Duration) async throws {
        // Intentionally a no-op.
    }
}
