import Foundation

/// The default routing policy: prefer on-device over network (latency,
/// cost, and privacy all favor it when it's capable), then prefer cheaper
/// cost tiers, using each provider's declared identifier as a final stable
/// tiebreaker so ordering is deterministic and testable rather than
/// depending on array/dictionary iteration order.
///
/// This is the concrete embodiment of the trade-off a staff engineer would
/// have to defend: "always try on-device first" is the right *default*
/// because it's free and private, but it is explicitly a swappable policy
/// (see `RoutingPolicy`) — a host app with different priorities (e.g.
/// always prefer the highest-capability provider regardless of cost) can
/// substitute its own without touching `ProviderRouter`.
public struct CapabilityAwareRoutingPolicy: RoutingPolicy {
    public init() {}

    public func order(candidates: [any LLMProvider], for request: LLMRequest) -> [any LLMProvider] {
        candidates.sorted { lhs, rhs in
            if lhs.capabilities.locality != rhs.capabilities.locality {
                return lhs.capabilities.locality == .onDevice
            }
            if lhs.capabilities.costTier != rhs.capabilities.costTier {
                return lhs.capabilities.costTier < rhs.capabilities.costTier
            }
            return lhs.identifier.rawValue < rhs.identifier.rawValue
        }
    }
}
