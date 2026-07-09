import Foundation

/// Observability hook so a host app (or this repo's own demo) can surface
/// which provider handled a request, and why a fallback happened, in a
/// golden-signals dashboard instead of only finding out via a support
/// ticket. Deliberately a plain closure rather than a delegate protocol —
/// there's exactly one thing to observe (a stream of events), so a
/// protocol would add ceremony without adding capability.
public enum RouterTelemetryEvent: Sendable {
    case attemptingProvider(ProviderIdentifier)
    case providerSucceeded(ProviderIdentifier)
    case providerFailed(ProviderIdentifier, reason: String)
    case toolCallExecuting(ToolCallRequest)
}

/// The orchestration core of this library: given a pool of `LLMProvider`s,
/// routes each request to the best available one, fails over to the next
/// candidate on error or an open circuit, and transparently drives a
/// provider's tool-calling round trips to completion.
///
/// ## Concurrency & ordering guarantees
/// `ProviderRouter` is an `actor`. Two guarantees fall out of that
/// directly and are worth stating explicitly, since a reviewer should not
/// have to infer them:
/// 1. **Per-request ordering is preserved.** Within a single `stream(_:)`
///    call, tool-call round trips execute strictly sequentially — the
///    router never issues round trip *n+1* before round trip *n*'s tool
///    result has been folded into the conversation. This is required for
///    correctness (round trip *n+1* depends on *n*'s result) and is
///    trivially true here because a single actor-isolated `run` loop drives
///    the whole exchange.
/// 2. **Concurrent requests do not corrupt shared routing state**, but they
///    *are* interleaved. Actor reentrancy means two overlapping
///    `stream(_:)` calls can suspend at the same `await` points inside
///    `CircuitBreaker` calls; each `CircuitBreaker` is itself an actor, so
///    its own state transitions stay race-free, but this router does
///    *not* serialize "attempt provider A" across unrelated requests —
///    concurrent throughput was judged more valuable than a stronger
///    (and unnecessary) global ordering guarantee across independent
///    conversations.
///
/// ## Rejected alternative: forwarding partial output during failover
/// A provider that fails mid-stream may have already produced several
/// `.textDelta` chunks. This router buffers those deltas per attempt and
/// only forwards them once the attempt reaches a terminal event
/// (`.completed`/`.toolCallRequested`); a failed attempt's deltas are
/// discarded entirely. The alternative — streaming deltas to the caller
/// immediately — was rejected because it can produce a user-visible,
/// half-formed sentence from a provider that then fails over to a second
/// provider starting a fresh answer from scratch. Buffering trades a small
/// amount of added latency (the whole first attempt must complete or fail
/// before anything is shown) for never displaying output that will be
/// silently abandoned.
public actor ProviderRouter {
    private let providers: [any LLMProvider]
    private let policy: any RoutingPolicy
    private let toolRegistry: ToolRegistry
    private var circuitBreakers: [ProviderIdentifier: CircuitBreaker] = [:]
    private let maxToolCallRoundTrips: Int
    private let observer: (@Sendable (RouterTelemetryEvent) -> Void)?

    public init(
        providers: [any LLMProvider],
        policy: any RoutingPolicy = CapabilityAwareRoutingPolicy(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        maxToolCallRoundTrips: Int = 4,
        circuitBreakerFactory: @Sendable (ProviderIdentifier) -> CircuitBreaker = { _ in CircuitBreaker() },
        observer: (@Sendable (RouterTelemetryEvent) -> Void)? = nil
    ) {
        precondition(maxToolCallRoundTrips > 0, "maxToolCallRoundTrips must be positive")
        let identifiers = providers.map(\.identifier)
        precondition(
            Set(identifiers).count == identifiers.count,
            "ProviderRouter requires providers to have unique identifiers"
        )
        self.providers = providers
        self.policy = policy
        self.toolRegistry = toolRegistry
        self.maxToolCallRoundTrips = maxToolCallRoundTrips
        self.observer = observer
        for provider in providers {
            self.circuitBreakers[provider.identifier] = circuitBreakerFactory(provider.identifier)
        }
    }

    /// Streams assistant text for `request`, transparently handling
    /// provider fallback and tool-calling round trips. The returned stream
    /// only ever emits `.textDelta` events followed by exactly one
    /// `.completed` event (or throws) — `.toolCallRequested` is an
    /// internal signal, never surfaced here, since a caller asked a
    /// question and expects an answer, not a tool-plumbing callback.
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.run(request, continuation: continuation)
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience for callers who only want the final text, not the
    /// incremental deltas.
    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        for try await event in stream(request) {
            if case .completed(let response) = event {
                return response
            }
        }
        // stream(_:) always either throws or yields exactly one `.completed`
        // before finishing — reaching end-of-sequence without one would be
        // a bug in `run`, not a state a well-behaved caller can hit.
        throw RouterError.allProvidersFailed([:])
    }

    private enum TerminalOutcome: Sendable {
        case completed(LLMResponse)
        case toolCallRequested(ToolCallRequest)
    }

    private func run(
        _ initialRequest: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws -> LLMResponse {
        guard !providers.isEmpty else { throw RouterError.noProvidersRegistered }

        var currentRequest = initialRequest
        var roundTrips = 0

        while true {
            try Task.checkCancellation()
            let outcome = try await attemptAcrossProviders(currentRequest, continuation: continuation)
            switch outcome {
            case .completed(let response):
                return response
            case .toolCallRequested(let call):
                roundTrips += 1
                if roundTrips > maxToolCallRoundTrips {
                    throw RouterError.toolCallLimitExceeded(rounds: roundTrips - 1)
                }
                observer?(.toolCallExecuting(call))
                let result = await toolRegistry.execute(call)
                let toolMessage = LLMMessage(role: .tool, content: result.messageContent, toolCallID: call.id)
                currentRequest = currentRequest.appending(toolMessage)
            }
        }
    }

    private func attemptAcrossProviders(
        _ request: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws -> TerminalOutcome {
        let capableProviders = providers.filter { $0.capabilities.canServe(request) }
        guard !capableProviders.isEmpty else { throw RouterError.noCapableProvider }

        let ordered = policy.order(candidates: capableProviders, for: request)
        var failures: [ProviderIdentifier: String] = [:]

        for provider in ordered {
            guard let breaker = circuitBreakers[provider.identifier] else {
                // Defensive: every provider got a breaker in init. If this
                // ever trips, treat the provider as unavailable rather than
                // crashing on a force-unwrap.
                failures[provider.identifier] = "no circuit breaker registered"
                continue
            }
            guard await breaker.allowsRequest() else {
                failures[provider.identifier] = "circuit open"
                continue
            }

            observer?(.attemptingProvider(provider.identifier))
            do {
                let (deltas, terminal) = try await drain(provider: provider, request: request)
                await breaker.recordSuccess()
                for delta in deltas {
                    continuation.yield(.textDelta(delta))
                }
                observer?(.providerSucceeded(provider.identifier))
                return terminal
            } catch {
                await breaker.recordFailure()
                let reason = String(describing: error)
                failures[provider.identifier] = reason
                observer?(.providerFailed(provider.identifier, reason: reason))
                continue
            }
        }

        throw RouterError.allProvidersFailed(failures)
    }

    /// Fully drains one provider's stream for a single attempt, buffering
    /// text deltas rather than forwarding them immediately (see the
    /// rejected-alternative note on the type). Throws if the underlying
    /// stream throws, or if it ends without a terminal event.
    private func drain(
        provider: any LLMProvider,
        request: LLMRequest
    ) async throws -> (deltas: [String], terminal: TerminalOutcome) {
        var deltas: [String] = []
        for try await event in provider.stream(request: request) {
            switch event {
            case .textDelta(let text):
                deltas.append(text)
            case .toolCallRequested(let call):
                return (deltas, .toolCallRequested(call))
            case .completed(let response):
                return (deltas, .completed(response))
            }
        }
        throw ProviderError.connectionFailed("provider stream ended without a terminal event")
    }
}
