import Foundation

/// A fully-formed request to send to a provider: the conversation so far,
/// the tools it's allowed to call, and generation parameters.
///
/// `LLMRequest` is what `ProviderCapabilities.canServe(_:)` inspects to
/// decide whether a provider can structurally handle the call — so it is
/// intentionally the single source of truth for "how big is this ask"
/// rather than letting each provider re-derive that independently.
public struct LLMRequest: Sendable, Equatable {
    public let messages: [LLMMessage]
    public let tools: [LLMToolDefinition]
    public let maxOutputTokens: Int
    public let temperature: Double

    public init(
        messages: [LLMMessage],
        tools: [LLMToolDefinition] = [],
        maxOutputTokens: Int = 512,
        temperature: Double = 0.7
    ) {
        precondition(maxOutputTokens > 0, "maxOutputTokens must be positive")
        precondition((0...2).contains(temperature), "temperature must be in 0...2")
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }

    /// Sum of the (approximate) input token cost plus the requested output
    /// budget — the number a capability check should compare against a
    /// provider's context window, since both input and reserved output
    /// space have to fit.
    public var estimatedTokenCount: Int {
        let inputTokens = messages.reduce(0) { $0 + $1.estimatedTokenCount }
        return inputTokens + maxOutputTokens
    }

    /// Returns a copy of this request with a message appended — used by
    /// the router to feed a tool's result back into the conversation
    /// without mutating the caller's original request.
    public func appending(_ message: LLMMessage) -> LLMRequest {
        LLMRequest(
            messages: messages + [message],
            tools: tools,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature
        )
    }
}
