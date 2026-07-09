import Foundation

/// Who authored a message in a conversation.
public enum LLMMessageRole: String, Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

/// A single turn in a conversation. Kept intentionally flat (no nested
/// attachments/multimodal payloads) — this library models the
/// routing/session/tool-calling contract, not a full chat-message schema.
public struct LLMMessage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let role: LLMMessageRole
    public let content: String
    /// Set only on `.tool` messages: which tool call this message answers.
    public let toolCallID: String?

    public init(
        id: UUID = UUID(),
        role: LLMMessageRole,
        content: String,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
    }

    /// Rough token estimate used for context-budget accounting. Real
    /// tokenizers are provider-specific and not something a portable
    /// gateway layer should hardcode; a conservative characters/4 heuristic
    /// is enough to make trimming decisions and is explicitly documented
    /// as an approximation rather than an exact count.
    public var estimatedTokenCount: Int {
        max(1, content.count / 4)
    }
}
