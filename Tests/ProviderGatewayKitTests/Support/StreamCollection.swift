import Foundation
@testable import ProviderGatewayKit

/// Drains a provider stream to completion.
///
/// Every simulated provider promises the same shape — some number of `.textDelta`
/// events followed by exactly one terminal event — so a helper that collects the
/// whole sequence lets a test assert on that shape rather than on the order the
/// events happened to arrive in.
func collect(
    _ stream: AsyncThrowingStream<LLMStreamEvent, Error>
) async throws -> [LLMStreamEvent] {
    var events: [LLMStreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

/// The assembled text of every `.textDelta` in a drained stream.
func joinedDeltas(_ events: [LLMStreamEvent]) -> String {
    events.compactMap { event -> String? in
        guard case .textDelta(let text) = event else { return nil }
        return text
    }
    .joined()
}

/// The single `.completed` response in a drained stream, if there is one.
func completedResponse(_ events: [LLMStreamEvent]) -> LLMResponse? {
    events.compactMap { event -> LLMResponse? in
        guard case .completed(let response) = event else { return nil }
        return response
    }
    .first
}

/// The single `.toolCallRequested` in a drained stream, if there is one.
func requestedToolCall(_ events: [LLMStreamEvent]) -> ToolCallRequest? {
    events.compactMap { event -> ToolCallRequest? in
        guard case .toolCallRequested(let call) = event else { return nil }
        return call
    }
    .first
}

/// A one-message request, which is what most of these tests need.
func userRequest(
    _ text: String,
    tools: [LLMToolDefinition] = [],
    maxOutputTokens: Int = 8
) -> LLMRequest {
    LLMRequest(
        messages: [LLMMessage(role: .user, content: text)],
        tools: tools,
        maxOutputTokens: maxOutputTokens
    )
}
