import XCTest
@testable import ProviderGatewayKit

/// The cloud provider, which is the one that can fail on cue.
///
/// `failureScript` is the reason this provider exists as a separate type rather than a
/// parameterisation of the others: a router test needs "call 1 rate-limits, call 2
/// succeeds" to be a fact rather than a probability.
final class SimulatedCloudProviderTests: XCTestCase {
    private func provider(
        identifier: ProviderIdentifier = .cloud,
        costTier: ProviderCostTier = .medium,
        maxContextTokens: Int = 32_000,
        failureScript: [Int: ProviderError] = [:]
    ) -> SimulatedCloudProvider {
        SimulatedCloudProvider(
            identifier: identifier,
            costTier: costTier,
            maxContextTokens: maxContextTokens,
            sleepClock: InstantSleepClock(),
            failureScript: failureScript
        )
    }

    func testDeclaresAFullyCapableNetworkProfile() {
        let subject = provider()
        XCTAssertEqual(subject.identifier, .cloud)
        XCTAssertTrue(subject.capabilities.supportsToolCalling)
        XCTAssertTrue(subject.capabilities.supportsStreaming)
        XCTAssertEqual(subject.capabilities.maxContextTokens, 32_000)
        XCTAssertEqual(subject.capabilities.costTier, .medium)
        XCTAssertEqual(subject.capabilities.locality, .network)
    }

    func testTheIdentifierAndTiersAreCallerSupplied() {
        let subject = provider(identifier: ProviderIdentifier("eu-west"), costTier: .high, maxContextTokens: 900)
        XCTAssertEqual(subject.identifier, ProviderIdentifier("eu-west"))
        XCTAssertEqual(subject.capabilities.costTier, .high)
        XCTAssertEqual(subject.capabilities.maxContextTokens, 900)
    }

    func testStreamsChunkedDeltasThatReassembleIntoTheCompletedText() async throws {
        let events = try await collect(provider().stream(request: userRequest("explain backpressure")))
        let response = try XCTUnwrap(completedResponse(events))

        XCTAssertEqual(response.providerID, .cloud)
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertTrue(response.text.contains("explain backpressure"))
        XCTAssertEqual(joinedDeltas(events), response.text)
        XCTAssertGreaterThan(events.count, 2, "a chunked reply should arrive in more than one delta")
    }

    /// The scripted failure is keyed on the call index, so the same provider value must
    /// fail the call it was told to and serve the one after it.
    func testAScriptedFailureHitsTheCallItNamesAndNoOther() async throws {
        let subject = provider(failureScript: [0: .rateLimited(retryAfter: .seconds(2))])

        do {
            _ = try await collect(subject.stream(request: userRequest("first")))
            XCTFail("expected call 0 to be rate limited")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .rateLimited(retryAfter: .seconds(2)))
        }

        let events = try await collect(subject.stream(request: userRequest("second")))
        XCTAssertNotNil(completedResponse(events), "call 1 was not scripted to fail")
    }

    func testEveryScriptedFailureKindReachesTheCaller() async throws {
        let cases: [ProviderError] = [
            .timeout,
            .rateLimited(retryAfter: nil),
            .connectionFailed("socket closed"),
            .capabilityMismatch("scripted")
        ]
        for expected in cases {
            do {
                _ = try await collect(provider(failureScript: [0: expected]).stream(request: userRequest("x")))
                XCTFail("expected \(expected)")
            } catch let error as ProviderError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testARequestExceedingTheContextWindowIsRefused() async {
        let subject = provider(maxContextTokens: 16)
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: String(repeating: "y", count: 4_000))],
            maxOutputTokens: 64
        )
        do {
            _ = try await collect(subject.stream(request: request))
            XCTFail("expected the cloud provider to refuse an oversized request")
        } catch let error as ProviderError {
            guard case .capabilityMismatch(let reason) = error else {
                return XCTFail("expected a capability mismatch, got \(error)")
            }
            XCTAssertTrue(reason.contains("context window"))
        } catch {
            XCTFail("expected a ProviderError, got \(error)")
        }
    }

    /// A tool call is terminal for the stream that requested it, and it is requested
    /// exactly once per conversation — otherwise the router's round-trip loop would
    /// never reach an answer.
    func testATooledRequestAsksForTheToolAndStopsThere() async throws {
        let definition = LLMToolDefinition(name: "weather", toolDescription: "look up weather")
        let events = try await collect(provider().stream(request: userRequest("weather?", tools: [definition])))

        let call = try XCTUnwrap(requestedToolCall(events))
        XCTAssertEqual(call.toolName, "weather")
        XCTAssertTrue(call.arguments.isEmpty)
        XCTAssertNil(completedResponse(events), "a tool request ends the stream without a completion")
    }

    func testOnceAToolHasAnsweredTheReplyUsesItsResultRatherThanAskingAgain() async throws {
        let definition = LLMToolDefinition(name: "weather", toolDescription: "look up weather")
        let request = LLMRequest(
            messages: [
                LLMMessage(role: .user, content: "weather?"),
                LLMMessage(role: .tool, content: "18C and raining", toolCallID: "call-1")
            ],
            tools: [definition],
            maxOutputTokens: 8
        )
        let events = try await collect(provider().stream(request: request))
        let response = try XCTUnwrap(completedResponse(events))

        XCTAssertNil(requestedToolCall(events), "the tool has already answered")
        XCTAssertTrue(response.text.contains("18C and raining"))
    }

    func testAbandoningTheStreamTerminatesTheProducer() async throws {
        var seen = 0
        for try await _ in provider().stream(request: userRequest("a long enough reply to chunk")) {
            seen += 1
            break
        }
        XCTAssertEqual(seen, 1)
    }
}
