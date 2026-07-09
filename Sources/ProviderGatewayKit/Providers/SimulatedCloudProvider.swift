import Foundation

/// A stand-in for a cloud-hosted model API: large context window, full
/// tool-calling support, higher latency and cost than on-device, and
/// subject to network failure modes (`ProviderError`) that a real HTTP
/// client would surface.
///
/// `failureScript` lets a test (or a demo app's "simulate flaky network"
/// toggle) deterministically inject a specific failure on specific call
/// indices, instead of relying on real network conditions or randomness.
public struct SimulatedCloudProvider: LLMProvider {
    public let identifier: ProviderIdentifier
    public let capabilities: ProviderCapabilities

    private let sleepClock: any SleepClock
    private let failureScript: [Int: ProviderError]
    private let callCounter: CallCounter

    public init(
        identifier: ProviderIdentifier = .cloud,
        costTier: ProviderCostTier = .medium,
        maxContextTokens: Int = 32_000,
        sleepClock: any SleepClock = RealSleepClock(),
        failureScript: [Int: ProviderError] = [:]
    ) {
        self.identifier = identifier
        self.capabilities = ProviderCapabilities(
            supportsToolCalling: true,
            supportsStreaming: true,
            maxContextTokens: maxContextTokens,
            costTier: costTier,
            locality: .network
        )
        self.sleepClock = sleepClock
        self.failureScript = failureScript
        self.callCounter = CallCounter()
    }

    public func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let callIndex = await callCounter.increment()
                do {
                    if let scriptedFailure = failureScript[callIndex] {
                        throw scriptedFailure
                    }
                    if !capabilities.canServe(request) {
                        throw ProviderError.capabilityMismatch(
                            "cloud provider cannot serve a request exceeding its context window"
                        )
                    }
                    try await sleepClock.sleep(for: .milliseconds(80))

                    if let pendingTool = Self.desiredToolCall(for: request) {
                        continuation.yield(.toolCallRequested(pendingTool))
                        continuation.finish()
                        return
                    }

                    let reply = Self.canned(for: request)
                    for chunk in Self.chunk(reply, size: 4) {
                        try Task.checkCancellation()
                        try await sleepClock.sleep(for: .milliseconds(20))
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.completed(
                        LLMResponse(text: reply, finishReason: .stop, providerID: identifier)
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// If the caller offered a tool and hasn't already answered a call to
    /// it, request it exactly once per conversation — enough to exercise
    /// the router's tool-calling loop without looping forever.
    private static func desiredToolCall(for request: LLMRequest) -> ToolCallRequest? {
        guard let firstTool = request.tools.first else { return nil }
        let alreadyAnswered = request.messages.contains { $0.role == .tool }
        guard !alreadyAnswered else { return nil }
        return ToolCallRequest(toolName: firstTool.name, arguments: [:])
    }

    private static func canned(for request: LLMRequest) -> String {
        if let toolMessage = request.messages.last(where: { $0.role == .tool }) {
            return "Cloud reply: using the tool result — \(toolMessage.content)"
        }
        let lastUserText = request.messages.last(where: { $0.role == .user })?.content ?? ""
        return "Cloud reply: a more thorough answer to \"\(lastUserText)\", drawing on a larger context window."
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0, !text.isEmpty else { return [text] }
        var result: [String] = []
        var current = text.startIndex
        while current < text.endIndex {
            let next = text.index(current, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[current..<next]))
            current = next
        }
        return result
    }
}

/// Tiny actor used only to make call-count tracking safe under concurrent
/// invocations of the same provider value (structs are `Sendable` but the
/// counter they close over needs its own isolation).
private actor CallCounter {
    private var count = 0
    func increment() -> Int {
        defer { count += 1 }
        return count
    }
}
