import Foundation

/// A single event in a provider's response stream. Providers emit an
/// ordered sequence of these; exactly one terminal event
/// (`.completed`, `.toolCallRequested`, or the stream throwing) ends the
/// stream — callers should not expect events after a terminal one.
public enum LLMStreamEvent: Sendable, Equatable {
    /// An incremental chunk of assistant text.
    case textDelta(String)
    /// The provider wants a tool executed before it can continue. This is
    /// terminal for the current stream — the router executes the tool(s)
    /// and issues a new request with the result appended.
    case toolCallRequested(ToolCallRequest)
    /// The provider finished its turn with no further tool calls pending.
    case completed(LLMResponse)
}

/// The final, assembled result of a provider turn.
public struct LLMResponse: Sendable, Equatable {
    public let text: String
    public let finishReason: FinishReason
    public let providerID: ProviderIdentifier

    public init(text: String, finishReason: FinishReason, providerID: ProviderIdentifier) {
        self.text = text
        self.finishReason = finishReason
        self.providerID = providerID
    }

    public enum FinishReason: Sendable, Equatable {
        case stop
        case maxTokens
        case toolCallLimitExceeded
    }
}
