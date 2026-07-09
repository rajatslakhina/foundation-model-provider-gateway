import Foundation

/// Stable identity for a registered `LLMProvider`.
///
/// Kept as a distinct type (rather than a bare `String`) so routing
/// decisions, circuit-breaker state, and telemetry events can all key off
/// the same value without accidentally mixing it up with a display name or
/// a model identifier string.
public struct ProviderIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

extension ProviderIdentifier {
    public static let onDevice = ProviderIdentifier("on-device")
    public static let cloud = ProviderIdentifier("cloud")
    public static let selfHosted = ProviderIdentifier("self-hosted")
}
