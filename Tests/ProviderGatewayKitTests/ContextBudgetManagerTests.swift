import XCTest
@testable import ProviderGatewayKit

final class ContextBudgetManagerTests: XCTestCase {
    func testEmptyHistoryReturnsEmpty() {
        let manager = ContextBudgetManager(maxTokens: 100)
        XCTAssertEqual(manager.fit([]), [])
    }

    func testAllMessagesKeptWhenWellUnderBudget() {
        let manager = ContextBudgetManager(maxTokens: 1_000)
        let messages = [
            LLMMessage(role: .system, content: "You are a helpful assistant."),
            LLMMessage(role: .user, content: "Hi"),
            LLMMessage(role: .assistant, content: "Hello!")
        ]
        XCTAssertEqual(manager.fit(messages), messages)
    }

    func testDropsOldestNonSystemMessagesFirst() {
        // Each message below is sized (via padding) to roughly 4 tokens
        // (16 chars / 4). A budget of 9 tokens leaves room for the system
        // message (4) plus exactly one more ~4-token message.
        let manager = ContextBudgetManager(maxTokens: 9)
        let system = LLMMessage(role: .system, content: "0123456789012345") // ~4 tokens
        let oldest = LLMMessage(role: .user, content: "aaaaaaaaaaaaaaaa") // ~4 tokens
        let newest = LLMMessage(role: .user, content: "bbbbbbbbbbbbbbbb") // ~4 tokens
        let result = manager.fit([system, oldest, newest])

        XCTAssertTrue(result.contains(system), "system message must never be dropped")
        XCTAssertTrue(result.contains(newest), "most recent message should be kept over an older one")
        XCTAssertFalse(result.contains(oldest), "oldest non-system message should be dropped when budget is tight")
    }

    func testSystemMessagesAloneExceedingBudgetReturnsOnlySystemMessages() {
        let manager = ContextBudgetManager(maxTokens: 2)
        let hugeSystem = LLMMessage(role: .system, content: String(repeating: "x", count: 400))
        let user = LLMMessage(role: .user, content: "hi")
        let result = manager.fit([hugeSystem, user])

        XCTAssertEqual(result, [hugeSystem], "should never drop the only message purely because it's oversized, and should never include a non-system message once the system budget alone is blown")
    }

    func testPreservesOriginalRelativeOrdering() {
        let manager = ContextBudgetManager(maxTokens: 10_000)
        let messages = [
            LLMMessage(role: .system, content: "sys"),
            LLMMessage(role: .user, content: "one"),
            LLMMessage(role: .assistant, content: "two"),
            LLMMessage(role: .user, content: "three")
        ]
        let result = manager.fit(messages)
        XCTAssertEqual(result.map(\.content), ["sys", "one", "two", "three"])
    }

    func testSingleOversizedNonSystemMessageIsDroppedNotTruncated() {
        let manager = ContextBudgetManager(maxTokens: 5)
        let hugeUser = LLMMessage(role: .user, content: String(repeating: "y", count: 1_000))
        let result = manager.fit([hugeUser])
        XCTAssertEqual(result, [], "an oversized message with no system messages present should be dropped, not partially included")
    }
}
