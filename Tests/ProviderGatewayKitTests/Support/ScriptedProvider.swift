import Foundation
@testable import ProviderGatewayKit

/// A fully scripted `LLMProvider` for deterministic router tests: each
/// call to `stream(request:)` consumes the next entry in `script`, so a
/// test can precisely dictate "call 1 fails, call 2 requests a tool, call
/// 3 succeeds" without relying on randomness or real timing.
actor ScriptedProvider: LLMProvider {
    enum ScriptedOutcome {
        case events([LLMStreamEvent])
        case failure(Error)
        /// Yields some deltas, then fails — used to test that the router
        /// discards a failed attempt's partial output instead of forwarding
        /// it to the caller before failing over.
        case eventsThenFailure(events: [LLMStreamEvent], error: Error)
    }

    nonisolated let identifier: ProviderIdentifier
    nonisolated let capabilities: ProviderCapabilities

    private var script: [ScriptedOutcome]
    private(set) var callCount = 0

    init(identifier: ProviderIdentifier, capabilities: ProviderCapabilities, script: [ScriptedOutcome]) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.script = script
    }

    nonisolated func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let outcome = await self.consumeNext()
                switch outcome {
                case .events(let events):
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .eventsThenFailure(let events, let error):
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish(throwing: error)
                case nil:
                    continuation.finish(throwing: ProviderError.connectionFailed("script exhausted for \(self.identifier)"))
                }
            }
        }
    }

    private func consumeNext() -> ScriptedOutcome? {
        callCount += 1
        guard !script.isEmpty else { return nil }
        return script.removeFirst()
    }
}
