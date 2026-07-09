import Foundation

/// A stand-in for Apple's on-device Foundation Models backend: fast, free,
/// privacy-preserving, but capacity-limited — a small context window and
/// (deliberately, for this demo) no tool-calling support, to exercise the
/// router's capability-based fallback path.
///
/// This library never links against a real on-device inference framework.
/// Simulated providers exist so the routing/session/tool-calling
/// architecture can be built, tested, and demonstrated headlessly and
/// deterministically — the same `LLMProvider` conformance is what a real
/// backend would implement in a host app.
public struct SimulatedOnDeviceProvider: LLMProvider {
    public let identifier: ProviderIdentifier = .onDevice
    public let capabilities = ProviderCapabilities(
        supportsToolCalling: false,
        supportsStreaming: true,
        maxContextTokens: 2_048,
        costTier: .free,
        locality: .onDevice
    )

    private let sleepClock: any SleepClock
    private let wordsPerChunk: Int

    public init(sleepClock: any SleepClock = RealSleepClock(), wordsPerChunk: Int = 3) {
        self.sleepClock = sleepClock
        self.wordsPerChunk = max(1, wordsPerChunk)
    }

    public func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if !capabilities.canServe(request) {
                        throw ProviderError.capabilityMismatch(
                            "on-device provider cannot serve requests with tools or an oversized context"
                        )
                    }
                    let reply = Self.canned(for: request)
                    let words = reply.split(separator: " ").map(String.init)
                    var buffer: [String] = []
                    for word in words {
                        try Task.checkCancellation()
                        buffer.append(word)
                        if buffer.count >= wordsPerChunk {
                            try await sleepClock.sleep(for: .milliseconds(15))
                            continuation.yield(.textDelta(buffer.joined(separator: " ") + " "))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(.textDelta(buffer.joined(separator: " ")))
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

    private static func canned(for request: LLMRequest) -> String {
        let lastUserText = request.messages.last(where: { $0.role == .user })?.content ?? ""
        if lastUserText.isEmpty {
            return "I don't have anything to respond to yet."
        }
        return "On-device reply: I can help with a quick answer to \"\(lastUserText)\" without leaving your device."
    }
}
