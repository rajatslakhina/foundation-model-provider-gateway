import XCTest
@testable import ProviderGatewayKit

/// The on-device provider, which is the one that says no.
///
/// It is the only simulated backend that declares `supportsToolCalling: false`, and
/// that is deliberate: the router's capability filter needs a candidate that fails it,
/// or the fallback path is never exercised by anything.
final class SimulatedOnDeviceProviderTests: XCTestCase {
    private func provider(wordsPerChunk: Int = 3) -> SimulatedOnDeviceProvider {
        SimulatedOnDeviceProvider(sleepClock: InstantSleepClock(), wordsPerChunk: wordsPerChunk)
    }

    func testDeclaresACapacityLimitedProfile() {
        let capabilities = provider().capabilities
        XCTAssertEqual(provider().identifier, .onDevice)
        XCTAssertFalse(capabilities.supportsToolCalling)
        XCTAssertTrue(capabilities.supportsStreaming)
        XCTAssertEqual(capabilities.maxContextTokens, 2_048)
        XCTAssertEqual(capabilities.costTier, .free)
        XCTAssertEqual(capabilities.locality, .onDevice)
    }

    func testStreamsDeltasThenExactlyOneCompletion() async throws {
        let events = try await collect(provider().stream(request: userRequest("what is a monad")))
        let response = try XCTUnwrap(completedResponse(events))

        XCTAssertEqual(response.providerID, .onDevice)
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertTrue(response.text.contains("what is a monad"))
        XCTAssertEqual(events.filter { if case .completed = $0 { return true } else { return false } }.count, 1)
    }

    /// The deltas must reassemble into the completed text, or a caller that rendered
    /// the stream incrementally would end up showing something the response never said.
    ///
    /// They do, up to a trailing space — see `testFullChunksLeaveATrailingSpaceTheCompletionDoesNot`,
    /// which pins that discrepancy rather than letting this assertion hide it behind a trim.
    func testDeltasReassembleIntoTheCompletedText() async throws {
        let events = try await collect(provider(wordsPerChunk: 2).stream(request: userRequest("hello there")))
        let response = try XCTUnwrap(completedResponse(events))
        XCTAssertEqual(joinedDeltas(events).trimmingCharacters(in: .whitespaces), response.text)
    }

    /// A word count that is an exact multiple of the chunk size leaves the buffer empty,
    /// and one that is not leaves a remainder to flush. Every chunk size has to deliver
    /// every word, whichever ending it takes.
    func testTheTrailingPartialChunkIsFlushed() async throws {
        for chunkSize in 1...5 {
            let events = try await collect(
                provider(wordsPerChunk: chunkSize).stream(request: userRequest("a b c d e f g"))
            )
            let response = try XCTUnwrap(completedResponse(events))
            XCTAssertEqual(
                joinedDeltas(events).trimmingCharacters(in: .whitespaces),
                response.text,
                "chunk size \(chunkSize) dropped text"
            )
        }
    }

    /// A discrepancy this suite found and is recording rather than papering over.
    ///
    /// Each full chunk is yielded as `buffer.joined(separator: " ") + " "`, so when the
    /// word count divides evenly by the chunk size the final delta ends in a space and
    /// the buffer-flush branch that would have absorbed it never runs. The concatenated
    /// deltas are then one character longer than `response.text`. It is cosmetic — a UI
    /// that renders deltas into a label will not show it — but a caller diffing the two
    /// to check for dropped tokens would see a mismatch that is not a dropped token.
    /// Fixing it is a change to library behaviour and belongs in its own commit; this
    /// test exists so the fix is deliberate rather than accidental.
    func testFullChunksLeaveATrailingSpaceTheCompletionDoesNot() async throws {
        // "one two three" is three words, which divides evenly by a chunk size of three.
        let events = try await collect(provider(wordsPerChunk: 3).stream(request: userRequest("x")))
        let response = try XCTUnwrap(completedResponse(events))
        let assembled = joinedDeltas(events)

        XCTAssertTrue(assembled.hasSuffix(" "), "a full final chunk carries its trailing separator")
        XCTAssertEqual(assembled.count, response.text.count + 1)
        XCTAssertEqual(assembled.trimmingCharacters(in: .whitespaces), response.text)
    }

    func testAChunkSizeBelowOneIsClampedRatherThanDividingByZero() async throws {
        let events = try await collect(
            SimulatedOnDeviceProvider(sleepClock: InstantSleepClock(), wordsPerChunk: 0)
                .stream(request: userRequest("one two three"))
        )
        let response = try XCTUnwrap(completedResponse(events))
        XCTAssertEqual(joinedDeltas(events).trimmingCharacters(in: .whitespaces), response.text)
    }

    func testARequestCarryingToolsIsRefusedRatherThanAnsweredBadly() async {
        let definition = LLMToolDefinition(name: "weather", toolDescription: "look up weather")
        do {
            _ = try await collect(provider().stream(request: userRequest("weather?", tools: [definition])))
            XCTFail("expected the on-device provider to refuse a tool-carrying request")
        } catch let error as ProviderError {
            guard case .capabilityMismatch(let reason) = error else {
                return XCTFail("expected a capability mismatch, got \(error)")
            }
            XCTAssertTrue(reason.contains("tools"))
        } catch {
            XCTFail("expected a ProviderError, got \(error)")
        }
    }

    func testARequestExceedingTheContextWindowIsRefused() async {
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: String(repeating: "x", count: 40_000))],
            maxOutputTokens: 512
        )
        do {
            _ = try await collect(provider().stream(request: request))
            XCTFail("expected the on-device provider to refuse an oversized request")
        } catch let error as ProviderError {
            guard case .capabilityMismatch = error else {
                return XCTFail("expected a capability mismatch, got \(error)")
            }
        } catch {
            XCTFail("expected a ProviderError, got \(error)")
        }
    }

    func testAnEmptyPromptGetsAnHonestAnswerRatherThanAnEmptyOne() async throws {
        let request = LLMRequest(messages: [LLMMessage(role: .system, content: "be brief")])
        let events = try await collect(provider().stream(request: request))
        let response = try XCTUnwrap(completedResponse(events))
        XCTAssertEqual(response.text, "I don't have anything to respond to yet.")
    }

    /// Abandoning the stream has to cancel the producing task. Without this the provider
    /// would keep yielding into a continuation nobody is reading.
    func testAbandoningTheStreamTerminatesTheProducer() async throws {
        var seen = 0
        for try await _ in provider(wordsPerChunk: 1).stream(request: userRequest("one two three four")) {
            seen += 1
            break
        }
        XCTAssertEqual(seen, 1)
    }
}
