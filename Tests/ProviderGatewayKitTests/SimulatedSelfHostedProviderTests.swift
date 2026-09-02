import XCTest
@testable import ProviderGatewayKit

/// The self-hosted provider, which is the one that fails on a cadence.
///
/// It exists so the circuit breaker has something realistic to trip on: a backend that
/// works most of the time and drops every Nth call is much harder to route around than
/// one that is simply up or down.
final class SimulatedSelfHostedProviderTests: XCTestCase {
    private func provider(
        identifier: ProviderIdentifier = .selfHosted,
        maxContextTokens: Int = 8_192,
        failEveryNCalls: Int = 0
    ) -> SimulatedSelfHostedProvider {
        SimulatedSelfHostedProvider(
            identifier: identifier,
            maxContextTokens: maxContextTokens,
            sleepClock: InstantSleepClock(),
            failEveryNCalls: failEveryNCalls
        )
    }

    func testDeclaresACheapMidSizedNetworkProfile() {
        let subject = provider()
        XCTAssertEqual(subject.identifier, .selfHosted)
        XCTAssertTrue(subject.capabilities.supportsToolCalling)
        XCTAssertTrue(subject.capabilities.supportsStreaming)
        XCTAssertEqual(subject.capabilities.maxContextTokens, 8_192)
        XCTAssertEqual(subject.capabilities.costTier, .low)
        XCTAssertEqual(subject.capabilities.locality, .network)
    }

    func testTheIdentifierAndWindowAreCallerSupplied() {
        let subject = provider(identifier: ProviderIdentifier("mlx-box"), maxContextTokens: 4_096)
        XCTAssertEqual(subject.identifier, ProviderIdentifier("mlx-box"))
        XCTAssertEqual(subject.capabilities.maxContextTokens, 4_096)
    }

    func testAReliableNodeAnswersInOneDeltaAndOneCompletion() async throws {
        let events = try await collect(provider().stream(request: userRequest("summarise this")))
        let response = try XCTUnwrap(completedResponse(events))

        XCTAssertEqual(response.providerID, .selfHosted)
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertTrue(response.text.contains("summarise this"))
        XCTAssertEqual(joinedDeltas(events), response.text)
    }

    /// The failure cadence is `(callIndex + 1) % n == 0`, so with `n == 2` the second
    /// call fails and the first and third do not. Pinning all three is what makes this
    /// a cadence rather than a coin toss.
    func testEveryNthCallFailsAndTheOthersDoNot() async throws {
        let subject = provider(failEveryNCalls: 2)

        let first = try await collect(subject.stream(request: userRequest("1")))
        XCTAssertNotNil(completedResponse(first))

        do {
            _ = try await collect(subject.stream(request: userRequest("2")))
            XCTFail("expected the second call to fail")
        } catch let error as ProviderError {
            guard case .connectionFailed(let reason) = error else {
                return XCTFail("expected a connection failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("unreachable"))
        }

        let third = try await collect(subject.stream(request: userRequest("3")))
        XCTAssertNotNil(completedResponse(third))
    }

    func testAZeroCadenceMeansTheNodeNeverFails() async throws {
        let subject = provider(failEveryNCalls: 0)
        for index in 1...4 {
            let events = try await collect(subject.stream(request: userRequest("\(index)")))
            XCTAssertNotNil(completedResponse(events), "call \(index) should have succeeded")
        }
    }

    func testANegativeCadenceIsClampedRatherThanTakenLiterally() async throws {
        let subject = SimulatedSelfHostedProvider(
            sleepClock: InstantSleepClock(),
            failEveryNCalls: -3
        )
        let events = try await collect(subject.stream(request: userRequest("hi")))
        XCTAssertNotNil(completedResponse(events))
    }

    func testARequestExceedingTheContextWindowIsRefused() async {
        let subject = provider(maxContextTokens: 16)
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: String(repeating: "z", count: 4_000))],
            maxOutputTokens: 64
        )
        do {
            _ = try await collect(subject.stream(request: request))
            XCTFail("expected the self-hosted provider to refuse an oversized request")
        } catch let error as ProviderError {
            guard case .capabilityMismatch(let reason) = error else {
                return XCTFail("expected a capability mismatch, got \(error)")
            }
            XCTAssertTrue(reason.contains("context window"))
        } catch {
            XCTFail("expected a ProviderError, got \(error)")
        }
    }

    func testAnEmptyPromptStillProducesAWellFormedReply() async throws {
        let request = LLMRequest(messages: [LLMMessage(role: .system, content: "be brief")])
        let events = try await collect(provider().stream(request: request))
        let response = try XCTUnwrap(completedResponse(events))
        XCTAssertTrue(response.text.contains("Self-hosted reply"))
    }

    func testAbandoningTheStreamTerminatesTheProducer() async throws {
        var seen = 0
        for try await _ in provider().stream(request: userRequest("hello")) {
            seen += 1
            break
        }
        XCTAssertEqual(seen, 1)
    }
}
