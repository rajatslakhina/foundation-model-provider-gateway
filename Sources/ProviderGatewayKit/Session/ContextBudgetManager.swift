import Foundation

/// Trims a conversation's message history so it fits inside a provider's
/// (or a policy's) token budget, without ever silently dropping the system
/// prompt — a truncation strategy that quietly removed the system message
/// under pressure would be a correctness bug (the assistant would start
/// improvising a persona/instructions), not an acceptable trade-off.
///
/// Trimming always drops the *oldest* non-system messages first, which
/// matches how most chat UIs behave (recent context is more relevant than
/// the start of a long conversation) and is a documented, swappable
/// default rather than the only possible policy — a host app with
/// different needs (e.g. summarizing dropped history instead of discarding
/// it) would implement that on top of this type, not inside it.
public struct ContextBudgetManager: Sendable {
    public let maxTokens: Int

    public init(maxTokens: Int) {
        precondition(maxTokens > 0, "maxTokens must be positive")
        self.maxTokens = maxTokens
    }

    /// Returns the largest suffix of `messages` (always including every
    /// `.system` message, regardless of position) whose combined estimated
    /// token count fits within `maxTokens`.
    ///
    /// Edge cases handled explicitly:
    /// - Empty input returns empty output.
    /// - If system messages alone exceed `maxTokens`, returns just the
    ///   system messages (never an empty result that would strip
    ///   instructions the caller explicitly set).
    /// - A single non-system message larger than the remaining budget is
    ///   dropped entirely rather than truncated mid-content, since a
    ///   partially-truncated message could change its meaning silently.
    public func fit(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard !messages.isEmpty else { return [] }

        let systemMessages = messages.filter { $0.role == .system }
        let otherMessages = messages.filter { $0.role != .system }
        let systemTokens = systemMessages.reduce(0) { $0 + $1.estimatedTokenCount }

        let remainingBudget = maxTokens - systemTokens
        guard remainingBudget > 0 else {
            return systemMessages
        }

        var budget = remainingBudget
        var kept: [LLMMessage] = []
        for message in otherMessages.reversed() {
            let cost = message.estimatedTokenCount
            guard cost <= budget else { break }
            kept.append(message)
            budget -= cost
        }
        kept.reverse()

        let keptIDs = Set(kept.map(\.id)).union(systemMessages.map(\.id))
        return messages.filter { keptIDs.contains($0.id) }
    }
}
