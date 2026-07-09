import XCTest
@testable import ProviderGatewayKit

private struct EchoTool: LLMTool {
    let definition = LLMToolDefinition(name: "echo", toolDescription: "Echoes its input back")

    func execute(arguments: [String: LLMToolArgumentValue]) async throws -> LLMToolResult {
        if case .string(let text)? = arguments["text"] {
            return .success(text)
        }
        return .failure("missing 'text' argument")
    }
}

private struct ThrowingTool: LLMTool {
    struct Boom: Error {}
    let definition = LLMToolDefinition(name: "boom", toolDescription: "Always throws")

    func execute(arguments: [String: LLMToolArgumentValue]) async throws -> LLMToolResult {
        throw Boom()
    }
}

final class ToolRegistryTests: XCTestCase {
    func testExecutesRegisteredTool() async {
        let registry = ToolRegistry(tools: [EchoTool()])
        let result = await registry.execute(
            ToolCallRequest(toolName: "echo", arguments: ["text": .string("hi")])
        )
        XCTAssertEqual(result, .success("hi"))
    }

    func testUnregisteredToolNameReturnsFailureNotCrash() async {
        let registry = ToolRegistry(tools: [])
        let result = await registry.execute(
            ToolCallRequest(toolName: "does-not-exist", arguments: [:])
        )
        guard case .failure = result else {
            return XCTFail("expected a .failure result for an unregistered tool name")
        }
    }

    func testThrowingToolIsTranslatedToFailureResult() async {
        let registry = ToolRegistry(tools: [ThrowingTool()])
        let result = await registry.execute(ToolCallRequest(toolName: "boom", arguments: [:]))
        guard case .failure = result else {
            return XCTFail("expected a thrown error to become a .failure result, not propagate")
        }
    }

    func testUnregisterRemovesTool() async {
        let registry = ToolRegistry(tools: [EchoTool()])
        await registry.unregister(named: "echo")
        let tool = await registry.tool(named: "echo")
        XCTAssertNil(tool)
    }

    func testDefinitionsAreSortedByName() async {
        let registry = ToolRegistry(tools: [ThrowingTool(), EchoTool()])
        let names = await registry.definitions.map(\.name)
        XCTAssertEqual(names, ["boom", "echo"])
    }
}
