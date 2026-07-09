import Foundation

/// Cost tier used by routing policies to prefer cheaper providers when
/// several candidates are otherwise equally capable of serving a request.
public enum ProviderCostTier: Int, Sendable, Comparable, CaseIterable {
    case free = 0
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: ProviderCostTier, rhs: ProviderCostTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where a provider physically executes inference. This affects both the
/// routing policy's default ordering (on-device is preferred when capable,
/// for latency/cost/privacy reasons) and how a session should think about
/// network-failure semantics.
public enum ProviderLocality: Sendable {
    case onDevice
    case network
}

/// Declares what a provider can do, so the router can filter out providers
/// that structurally cannot serve a given request (e.g. no tool-calling
/// support) instead of discovering that only after a failed round trip.
public struct ProviderCapabilities: Sendable, Equatable {
    public let supportsToolCalling: Bool
    public let supportsStreaming: Bool
    public let maxContextTokens: Int
    public let costTier: ProviderCostTier
    public let locality: ProviderLocality

    public init(
        supportsToolCalling: Bool,
        supportsStreaming: Bool,
        maxContextTokens: Int,
        costTier: ProviderCostTier,
        locality: ProviderLocality
    ) {
        precondition(maxContextTokens >= 0, "maxContextTokens must be non-negative")
        self.supportsToolCalling = supportsToolCalling
        self.supportsStreaming = supportsStreaming
        self.maxContextTokens = maxContextTokens
        self.costTier = costTier
        self.locality = locality
    }

    /// Whether this provider can structurally serve `request` at all,
    /// independent of runtime availability (circuit-breaker state, etc).
    public func canServe(_ request: LLMRequest) -> Bool {
        if !request.tools.isEmpty && !supportsToolCalling {
            return false
        }
        // A request whose message history already exceeds this provider's
        // window can never be served by it, regardless of retries.
        if request.estimatedTokenCount > maxContextTokens {
            return false
        }
        return true
    }
}

extension ProviderLocality: Equatable {}
