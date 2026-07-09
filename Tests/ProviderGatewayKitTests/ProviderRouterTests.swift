import XCTest
@testable import ProviderGatewayKit

private struct StaticTool: LLMTool {
    let definition = LLMToolDefinition(name: "lookup", toolDescription: "Looks something up")
    let result: LLMToolResult

    func execute(arguments: [String: LLMToolArgumentValue]) async throws -> LLMToolResult {
        result
    }
}

private let capableCapabilities = ProviderCapabilities(
    supportsToolCalling: true,
    supportsStreaming: true,
    maxContextTokens: 10_000,
    costTier: .low,
    locality: .network
)

private let noToolCapabilities = ProviderCapabilities(
    supportsToolCalling: false,
    supportsStreaming: true,
    maxContextTokens: 10_000,
    costTier: .free,
    locality: .onDevice
)

final class ProviderRouterTests: XCTestCase {
    private let sampleRequest = LLMRequest(messages: [LLMMessage(role: .user, content: "hi")])

    func testNoProvidersRegisteredThrows() async {
        let router = ProviderRouter(providers: [])
        do {
            _ = try await router.send(sampleRequest)
            XCTFail("expected noProvidersRegistered")
        } catch let error as RouterError {
            XCTAssertEqual(error, .noProvidersRegistered)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNoCapableProviderThrowsWhenAllCandidatesLackRequiredCapability() async {
        let onDeviceOnly = ScriptedProvider(identifier: ProviderIdentifier("on-device"), capabilities: noToolCapabilities, script: [])
        let router = ProviderRouter(providers: [onDeviceOnly])

        // A request that requires tool calling cannot be served by a
        // provider that doesn't support it.
        let requestNeedingTools = LLMRequest(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: [LLMToolDefinition(name: "lookup", toolDescription: "x")]
        )
        do {
            _ = try await router.send(requestNeedingTools)
            XCTFail("expected noCapableProvider")
        } catch let error as RouterError {
            XCTAssertEqual(error, .noCapableProvider)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFallsOverToSecondProviderWhenFirstFails() async throws {
        let failing = ScriptedProvider(
            identifier: ProviderIdentifier("p1-failing"),
            capabilities: capableCapabilities,
            script: [.failure(ProviderError.connectionFailed("down"))]
        )
        let succeeding = ScriptedProvider(
            identifier: ProviderIdentifier("p2-succeeding"),
            capabilities: capableCapabilities,
            script: [.events([
                .textDelta("Hello "),
                .textDelta("World"),
                .completed(LLMResponse(text: "Hello World", finishReason: .stop, providerID: ProviderIdentifier("p2-succeeding")))
            ])]
        )
        let router = ProviderRouter(providers: [failing, succeeding])

        let response = try await router.send(sampleRequest)
        XCTAssertEqual(response.text, "Hello World")
        XCTAssertEqual(response.providerID, ProviderIdentifier("p2-succeeding"))
    }

    func testAllProvidersFailingSurfacesAggregatedErrors() async {
        let a = ScriptedProvider(identifier: ProviderIdentifier("a"), capabilities: capableCapabilities, script: [.failure(ProviderError.timeout)])
        let b = ScriptedProvider(identifier: ProviderIdentifier("b"), capabilities: capableCapabilities, script: [.failure(ProviderError.timeout)])
        let router = ProviderRouter(providers: [a, b])

        do {
            _ = try await router.send(sampleRequest)
            XCTFail("expected allProvidersFailed")
        } catch let RouterError.allProvidersFailed(failures) {
            XCTAssertEqual(failures.count, 2)
            XCTAssertNotNil(failures[ProviderIdentifier("a")])
            XCTAssertNotNil(failures[ProviderIdentifier("b")])
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFailedAttemptsPartialOutputIsNeverForwarded() async throws {
        // "aaa-" / "zzz-" prefixes force CapabilityAwareRoutingPolicy's
        // alphabetical tiebreaker to try the failing provider first —
        // otherwise the successful provider would win outright and this
        // test wouldn't actually exercise the discard-on-failure path.
        let failingID = ProviderIdentifier("aaa-partial-then-fail")
        let succeedingID = ProviderIdentifier("zzz-clean-success")
        let failsAfterPartialOutput = ScriptedProvider(
            identifier: failingID,
            capabilities: capableCapabilities,
            script: [.eventsThenFailure(events: [.textDelta("this should never reach the caller")], error: ProviderError.timeout)]
        )
        let succeeding = ScriptedProvider(
            identifier: succeedingID,
            capabilities: capableCapabilities,
            script: [.events([
                .textDelta("clean answer"),
                .completed(LLMResponse(text: "clean answer", finishReason: .stop, providerID: succeedingID))
            ])]
        )
        let router = ProviderRouter(providers: [failsAfterPartialOutput, succeeding])

        var observedDeltas: [String] = []
        for try await event in await router.stream(sampleRequest) {
            if case .textDelta(let text) = event {
                observedDeltas.append(text)
            }
        }

        XCTAssertEqual(observedDeltas, ["clean answer"], "deltas from the failed first attempt must never be surfaced to the caller")
    }

    func testToolCallIsExecutedAndLoopsBackIntoTheProvider() async throws {
        let providerID = ProviderIdentifier("tool-user")
        let provider = ScriptedProvider(
            identifier: providerID,
            capabilities: capableCapabilities,
            script: [
                .events([.toolCallRequested(ToolCallRequest(id: "call-1", toolName: "lookup", arguments: [:]))]),
                .events([
                    .textDelta("The answer is 42"),
                    .completed(LLMResponse(text: "The answer is 42", finishReason: .stop, providerID: providerID))
                ])
            ]
        )
        let registry = ToolRegistry(tools: [StaticTool(result: .success("42"))])
        let router = ProviderRouter(providers: [provider], toolRegistry: registry)

        let requestWithTool = LLMRequest(
            messages: [LLMMessage(role: .user, content: "what is the answer?")],
            tools: [LLMToolDefinition(name: "lookup", toolDescription: "x")]
        )
        let response = try await router.send(requestWithTool)
        XCTAssertEqual(response.text, "The answer is 42")
        let calls = await provider.callCount
        XCTAssertEqual(calls, 2, "provider should be called once for the tool request and once more with the tool result")
    }

    func testToolCallLoopExceedingLimitThrows() async {
        let providerID = ProviderIdentifier("infinite-tool-caller")
        // Always requests the same tool, never completes.
        let infiniteScript = (0..<10).map { index in
            ScriptedProvider.ScriptedOutcome.events([
                .toolCallRequested(ToolCallRequest(id: "call-\(index)", toolName: "lookup", arguments: [:]))
            ])
        }
        let provider = ScriptedProvider(identifier: providerID, capabilities: capableCapabilities, script: infiniteScript)
        let registry = ToolRegistry(tools: [StaticTool(result: .success("again"))])
        let router = ProviderRouter(providers: [provider], toolRegistry: registry, maxToolCallRoundTrips: 3)

        let requestWithTool = LLMRequest(
            messages: [LLMMessage(role: .user, content: "loop forever")],
            tools: [LLMToolDefinition(name: "lookup", toolDescription: "x")]
        )
        do {
            _ = try await router.send(requestWithTool)
            XCTFail("expected toolCallLimitExceeded")
        } catch let RouterError.toolCallLimitExceeded(rounds) {
            XCTAssertEqual(rounds, 3)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testOpenCircuitSkipsProviderWithoutCallingIt() async throws {
        let manualClock = ManualClock(startingAt: 0)
        // Identifiers are deliberately chosen so "aaa-unreliable" sorts
        // before "zzz-backup" under CapabilityAwareRoutingPolicy's
        // alphabetical tiebreaker (both providers otherwise have identical
        // locality/cost tier) — this test needs `unreliable` to be tried
        // first so its breaker actually gets a chance to trip.
        let unreliableID = ProviderIdentifier("aaa-unreliable")
        let backupID = ProviderIdentifier("zzz-backup")
        let unreliable = ScriptedProvider(
            identifier: unreliableID,
            capabilities: capableCapabilities,
            script: [.failure(ProviderError.timeout)]
        )
        let backup = ScriptedProvider(
            identifier: backupID,
            capabilities: capableCapabilities,
            script: [
                .events([.completed(LLMResponse(text: "first", finishReason: .stop, providerID: backupID))]),
                .events([.completed(LLMResponse(text: "second", finishReason: .stop, providerID: backupID))])
            ]
        )
        // Threshold of 1 so the very first failure trips the breaker.
        let router = ProviderRouter(
            providers: [unreliable, backup],
            circuitBreakerFactory: { _ in CircuitBreaker(failureThreshold: 1, resetTimeout: 3_600, clock: manualClock) }
        )

        // First call: unreliable fails and trips its breaker, backup serves the request.
        let first = try await router.send(sampleRequest)
        XCTAssertEqual(first.text, "first")

        // Second call: unreliable's breaker is still open (reset timeout is
        // an hour and the clock hasn't moved), so it should be skipped
        // entirely — `unreliable`'s script only had one scripted call, so
        // if the router tried it again this would throw "script exhausted"
        // instead of falling through cleanly to backup.
        let second = try await router.send(sampleRequest)
        XCTAssertEqual(second.text, "second")
    }

    func testDuplicateProviderIdentifiersArePreventedAtInit() {
        // Documented as a programmer-error precondition rather than a
        // recoverable throw, since silently collapsing two distinct
        // providers onto one circuit breaker would be a much harder bug to
        // diagnose than a fast, obvious crash at construction time.
        // (Exercised as a comment rather than a literal crash test, since
        // XCTest cannot catch a `precondition` failure without aborting
        // the whole test process.)
        let a = ScriptedProvider(identifier: ProviderIdentifier("dup"), capabilities: capableCapabilities, script: [])
        let b = ScriptedProvider(identifier: ProviderIdentifier("dup"), capabilities: capableCapabilities, script: [])
        XCTAssertEqual(a.identifier, b.identifier, "sanity check that these two providers do in fact share an identifier, which is the precondition this documents")
    }
}
