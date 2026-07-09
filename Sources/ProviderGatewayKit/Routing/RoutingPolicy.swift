import Foundation

/// Decides the *order* in which capable providers should be tried for a
/// given request. Kept as a protocol (rather than hardcoding a single
/// heuristic into the router) so a host app can swap in its own policy —
/// e.g. "always prefer whichever provider answered fastest in the last
/// hour" — without touching routing, fallback, or circuit-breaker logic.
///
/// Implementations receive only structurally-capable candidates (the
/// router has already filtered out providers that fail
/// `ProviderCapabilities.canServe(_:)`); a policy is purely about
/// preference ordering among viable options, not eligibility.
public protocol RoutingPolicy: Sendable {
    func order(candidates: [any LLMProvider], for request: LLMRequest) -> [any LLMProvider]
}
