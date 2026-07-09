import Foundation

/// Errors surfaced by `ProviderRouter` itself, as distinct from
/// `ProviderError`s thrown by an individual provider — these represent the
/// router exhausting its own options, not a single backend's failure.
public enum RouterError: Error, Sendable, Equatable {
    /// No provider was registered at all.
    case noProvidersRegistered
    /// At least one provider exists, but none can structurally serve this
    /// request (capability mismatch on every candidate).
    case noCapableProvider
    /// Every capable candidate was tried (in fallback order) and every one
    /// failed or had an open circuit. Carries the per-provider errors so
    /// callers can distinguish "everything is rate limited" from
    /// "everything is down" instead of a single opaque failure.
    case allProvidersFailed([ProviderIdentifier: String])
    /// A provider kept requesting tool calls past `maxToolCallRoundTrips`,
    /// which almost always indicates either a buggy provider or a tool
    /// whose result the provider can't parse — better to fail loudly than
    /// spin forever.
    case toolCallLimitExceeded(rounds: Int)
}
