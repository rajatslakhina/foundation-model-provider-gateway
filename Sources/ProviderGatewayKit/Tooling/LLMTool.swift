import Foundation

/// A callable capability the router can hand to a provider. Consumers of
/// this library implement this protocol for their own app-specific actions
/// (fetch weather, query a database, control a UI element, etc).
///
/// Execution is `async throws` deliberately: a tool doing real I/O should
/// be able to fail, and the router treats a thrown error the same as an
/// explicit `.failure` result (both become a `.tool` message so the
/// provider can react to it) rather than aborting the whole turn.
public protocol LLMTool: Sendable {
    var definition: LLMToolDefinition { get }
    func execute(arguments: [String: LLMToolArgumentValue]) async throws -> LLMToolResult
}

/// Thread-safe (actor-isolated) lookup table from tool name to
/// implementation. A plain `[String: any LLMTool]` dictionary captured in a
/// closure would work for a single call site, but an actor lets the same
/// registry be shared safely across concurrent `LLMSession`s.
public actor ToolRegistry {
    private var toolsByName: [String: any LLMTool] = [:]

    public init(tools: [any LLMTool] = []) {
        for tool in tools {
            toolsByName[tool.definition.name] = tool
        }
    }

    public func register(_ tool: any LLMTool) {
        toolsByName[tool.definition.name] = tool
    }

    public func unregister(named name: String) {
        toolsByName.removeValue(forKey: name)
    }

    public func tool(named name: String) -> (any LLMTool)? {
        toolsByName[name]
    }

    public var definitions: [LLMToolDefinition] {
        toolsByName.values.map(\.definition).sorted { $0.name < $1.name }
    }

    /// Executes a requested tool call, translating "tool not found" into a
    /// `.failure` result rather than throwing — an unregistered tool name
    /// is a valid (if unfortunate) conversational outcome the provider
    /// should be told about, not a crash or an unhandled router error.
    public func execute(_ request: ToolCallRequest) async -> LLMToolResult {
        guard let tool = toolsByName[request.toolName] else {
            return .failure("No tool registered with name '\(request.toolName)'")
        }
        do {
            return try await tool.execute(arguments: request.arguments)
        } catch {
            return .failure(String(describing: error))
        }
    }
}
