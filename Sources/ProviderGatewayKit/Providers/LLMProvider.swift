import Foundation

/// The contract every model backend — on-device, cloud, self-hosted, or
/// anything else a future SDK exposes — must satisfy to plug into
/// `ProviderRouter`. This is the seam this whole library exists to define:
/// consumers can add a real backend (wrapping Apple's on-device Foundation
/// Models API, a cloud HTTP client, an MLX-hosted fine-tune, etc.) by
/// conforming to this protocol, with zero changes to routing, fallback,
/// circuit-breaking, or session logic.
public protocol LLMProvider: Sendable {
    var identifier: ProviderIdentifier { get }
    var capabilities: ProviderCapabilities { get }

    /// Streams a response to `request`. Implementations should throw
    /// (ending the stream) for transport-level failures — timeouts, rate
    /// limits, connection drops — so the router's circuit breaker and
    /// fallback chain can react. A `.toolCallRequested` event is not an
    /// error: it is a normal, terminal event the router handles by
    /// executing the tool and re-invoking the provider.
    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

/// Errors a provider (real or simulated) can throw from `stream(request:)`.
public enum ProviderError: Error, Sendable, Equatable {
    case timeout
    case rateLimited(retryAfter: Duration?)
    case connectionFailed(String)
    case capabilityMismatch(String)
}
