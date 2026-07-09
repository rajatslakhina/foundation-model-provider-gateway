import Foundation

/// A stand-in for a self-hosted fine-tune (the third leg the newly-opened
/// Foundation Models provider protocol enables) — cheaper than the cloud
/// provider and mid-sized context, but modeled here as unreliable
/// (`failureRate` throws `.connectionFailed` on a deterministic cadence)
/// so it's a realistic candidate for the circuit breaker to trip on.
public struct SimulatedSelfHostedProvider: LLMProvider {
    public let identifier: ProviderIdentifier
    public let capabilities: ProviderCapabilities

    private let sleepClock: any SleepClock
    /// Every Nth call fails with a connection error; 0 disables failures.
    private let failEveryNCalls: Int
    private let callCounter: CallCounter

    public init(
        identifier: ProviderIdentifier = .selfHosted,
        maxContextTokens: Int = 8_192,
        sleepClock: any SleepClock = RealSleepClock(),
        failEveryNCalls: Int = 0
    ) {
        self.identifier = identifier
        self.capabilities = ProviderCapabilities(
            supportsToolCalling: true,
            supportsStreaming: true,
            maxContextTokens: maxContextTokens,
            costTier: .low,
            locality: .network
        )
        self.sleepClock = sleepClock
        self.failEveryNCalls = max(0, failEveryNCalls)
        self.callCounter = CallCounter()
    }

    public func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let callIndex = await callCounter.increment()
                do {
                    if failEveryNCalls > 0, (callIndex + 1) % failEveryNCalls == 0 {
                        throw ProviderError.connectionFailed("self-hosted node unreachable (call #\(callIndex))")
                    }
                    if !capabilities.canServe(request) {
                        throw ProviderError.capabilityMismatch(
                            "self-hosted provider cannot serve a request exceeding its context window"
                        )
                    }
                    try await sleepClock.sleep(for: .milliseconds(50))
                    let lastUserText = request.messages.last(where: { $0.role == .user })?.content ?? ""
                    let reply = "Self-hosted reply: a locally-served answer to \"\(lastUserText)\"."
                    continuation.yield(.textDelta(reply))
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
}

private actor CallCounter {
    private var count = 0
    func increment() -> Int {
        defer { count += 1 }
        return count
    }
}
