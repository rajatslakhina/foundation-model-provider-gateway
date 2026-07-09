import Foundation

/// A stateful conversation on top of `ProviderRouter`: owns message
/// history, applies the context budget before each request, and appends
/// both sides of each turn back into the transcript.
///
/// ## Concurrency & ordering guarantee
/// `send(_:)` turns are strictly serialized in call order, even if a
/// caller fires off multiple `send` calls concurrently without awaiting
/// each one first. This is deliberate and enforced (not just "usually
/// true because it's an actor"): actor reentrancy alone is *not* enough
/// to prevent turn interleaving, because `send` suspends at the
/// `router.send(...)` await point, and a naive implementation would let a
/// second concurrent call append its user message and build its request
/// (missing the first call's still-in-flight assistant reply) before the
/// first call finishes. That would silently reorder a conversation and
/// build requests against a stale/incomplete transcript — an out-of-order
/// delivery bug that would be very hard to notice in normal testing since
/// it only shows up under real concurrent load.
///
/// The fix is an explicit FIFO turn lock (`acquireTurnLock`/
/// `releaseTurnLock`) built on `CheckedContinuation`: a turn does not begin
/// building its request until every earlier-submitted turn has fully
/// completed (including appending its assistant reply). See
/// `LLMSessionTests.testConcurrentSendsAreProcessedInSubmissionOrder` for
/// the regression test this guarantee is designed to satisfy.
public actor LLMSession {
    private let router: ProviderRouter
    private let budgetManager: ContextBudgetManager
    private let tools: [LLMToolDefinition]
    private let maxOutputTokens: Int
    private let temperature: Double

    private var history: [LLMMessage]

    private var isProcessingTurn = false
    private var waitingTurns: [CheckedContinuation<Void, Never>] = []

    public init(
        router: ProviderRouter,
        systemPrompt: String? = nil,
        budgetManager: ContextBudgetManager = ContextBudgetManager(maxTokens: 4_000),
        tools: [LLMToolDefinition] = [],
        maxOutputTokens: Int = 512,
        temperature: Double = 0.7
    ) {
        self.router = router
        self.budgetManager = budgetManager
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        if let systemPrompt, !systemPrompt.isEmpty {
            self.history = [LLMMessage(role: .system, content: systemPrompt)]
        } else {
            self.history = []
        }
    }

    /// A snapshot of the conversation so far, in chronological order.
    public func currentTranscript() -> [LLMMessage] {
        history
    }

    /// Sends a user turn, waits for its assistant reply, appends both to
    /// the transcript, and returns the reply. See the type-level doc for
    /// the ordering guarantee this provides under concurrent callers.
    @discardableResult
    public func send(_ userText: String) async throws -> LLMResponse {
        await acquireTurnLock()
        defer { releaseTurnLock() }

        let userMessage = LLMMessage(role: .user, content: userText)
        history.append(userMessage)

        let request = LLMRequest(
            messages: budgetManager.fit(history),
            tools: tools,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature
        )

        do {
            let response = try await router.send(request)
            history.append(LLMMessage(role: .assistant, content: response.text))
            return response
        } catch {
            // Roll back the user message so a failed turn doesn't leave an
            // unanswered question permanently in the transcript — the
            // caller can retry `send` cleanly, and the next successful
            // turn's context won't include a dangling, unanswered user
            // message that no provider ever saw a reply to.
            if history.last?.id == userMessage.id {
                history.removeLast()
            }
            throw error
        }
    }

    private func acquireTurnLock() async {
        if !isProcessingTurn {
            isProcessingTurn = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitingTurns.append(continuation)
        }
        isProcessingTurn = true
    }

    private func releaseTurnLock() {
        guard !waitingTurns.isEmpty else {
            isProcessingTurn = false
            return
        }
        let next = waitingTurns.removeFirst()
        next.resume()
    }
}
