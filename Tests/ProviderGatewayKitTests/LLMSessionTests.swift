import XCTest
@testable import ProviderGatewayKit

/// A provider that echoes back a reply derived from the *last* user
/// message it was asked about, after an artificial suspension point — used
/// to make out-of-order interleaving observable if `LLMSession` didn't
/// serialize turns.
private actor EchoingProvider: LLMProvider {
    nonisolated let identifier = ProviderIdentifier("echo")
    nonisolated let capabilities = ProviderCapabilities(
        supportsToolCalling: false,
        supportsStreaming: true,
        maxContextTokens: 100_000,
        costTier: .free,
        locality: .onDevice
    )

    nonisolated func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Yield control at least once before replying, so a
                // concurrency bug (two turns building requests before
                // either completes) would have a real chance to manifest.
                await Task.yield()
                let lastUser = request.messages.last(where: { $0.role == .user })?.content ?? "<none>"
                let reply = "reply-to:\(lastUser)"
                continuation.yield(.textDelta(reply))
                continuation.yield(.completed(LLMResponse(text: reply, finishReason: .stop, providerID: ProviderIdentifier("echo"))))
                continuation.finish()
            }
        }
    }
}

private struct AlwaysFailingProvider: LLMProvider {
    let identifier = ProviderIdentifier("always-fails")
    let capabilities = ProviderCapabilities(
        supportsToolCalling: false,
        supportsStreaming: true,
        maxContextTokens: 100_000,
        costTier: .free,
        locality: .onDevice
    )

    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.connectionFailed("nope"))
        }
    }
}

final class LLMSessionTests: XCTestCase {
    func testSendAppendsUserAndAssistantMessagesInOrder() async throws {
        let router = ProviderRouter(providers: [EchoingProvider()])
        let session = LLMSession(router: router, systemPrompt: "sys")

        _ = try await session.send("first")
        let transcript = await session.currentTranscript()

        XCTAssertEqual(transcript.map(\.role), [.system, .user, .assistant])
        XCTAssertEqual(transcript[1].content, "first")
        XCTAssertEqual(transcript[2].content, "reply-to:first")
    }

    func testFailedTurnRollsBackTheUnansweredUserMessage() async {
        let router = ProviderRouter(providers: [AlwaysFailingProvider()])
        let session = LLMSession(router: router)

        do {
            _ = try await session.send("will fail")
            XCTFail("expected the send to throw")
        } catch {
            // expected
        }

        let transcript = await session.currentTranscript()
        XCTAssertTrue(transcript.isEmpty, "a failed turn should not leave an orphaned, unanswered user message in the transcript")
    }

    func testConcurrentSendsAreProcessedInSubmissionOrder() async throws {
        let router = ProviderRouter(providers: [EchoingProvider()])
        let session = LLMSession(router: router)

        // Fire off several sends without awaiting each one first — if
        // LLMSession didn't serialize turns, these could interleave and
        // produce a transcript where a later call's user message appears
        // before an earlier call's assistant reply.
        async let first = session.send("A")
        async let second = session.send("B")
        async let third = session.send("C")
        _ = try await (first, second, third)

        let transcript = await session.currentTranscript()
        XCTAssertEqual(transcript.count, 6, "3 user + 3 assistant messages")

        // Turns must appear as strict (user, assistant) pairs — never two
        // user messages back-to-back, which would indicate a second turn's
        // request was built before the first turn's reply was appended.
        var index = transcript.startIndex
        while index < transcript.endIndex {
            XCTAssertEqual(transcript[index].role, .user, "expected a user message at position \(index)")
            let nextIndex = transcript.index(after: index)
            guard nextIndex < transcript.endIndex else {
                return XCTFail("user message at \(index) has no matching assistant reply")
            }
            XCTAssertEqual(transcript[nextIndex].role, .assistant, "expected an assistant reply immediately after the user message at \(index)")
            XCTAssertEqual(transcript[nextIndex].content, "reply-to:\(transcript[index].content)", "each assistant reply must answer its own immediately-preceding user message, not a later one")
            index = transcript.index(after: nextIndex)
        }
    }

    func testBudgetManagerTrimsHistoryBeforeSending() async throws {
        // A capturing provider lets the test assert on exactly what
        // request the router received, proving the session applied its
        // budget manager rather than sending raw, untrimmed history.
        let capture = CapturingProvider()
        let router = ProviderRouter(providers: [capture])
        let tightBudget = ContextBudgetManager(maxTokens: 9) // enough for system + ~1 short turn, forcing the older turn out once a second turn is added
        let session = LLMSession(router: router, systemPrompt: "sys", budgetManager: tightBudget)

        _ = try await session.send("aaaaaaaaaaaaaaaa") // ~4 tokens
        _ = try await session.send("bbbbbbbbbbbbbbbb") // ~4 tokens, should push out the first turn

        let lastRequest = await capture.lastRequest
        let userContents = lastRequest?.messages.filter { $0.role == .user }.map(\.content) ?? []
        XCTAssertFalse(userContents.contains("aaaaaaaaaaaaaaaa"), "oldest turn should have been trimmed from the outgoing request once the budget got tight")
    }
}

private actor CapturingProvider: LLMProvider {
    nonisolated let identifier = ProviderIdentifier("capturing")
    nonisolated let capabilities = ProviderCapabilities(
        supportsToolCalling: false,
        supportsStreaming: true,
        maxContextTokens: 100_000,
        costTier: .free,
        locality: .onDevice
    )

    private(set) var lastRequest: LLMRequest?

    nonisolated func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                continuation.yield(.completed(LLMResponse(text: "ok", finishReason: .stop, providerID: ProviderIdentifier("capturing"))))
                continuation.finish()
            }
        }
    }

    private func record(_ request: LLMRequest) {
        lastRequest = request
    }
}
