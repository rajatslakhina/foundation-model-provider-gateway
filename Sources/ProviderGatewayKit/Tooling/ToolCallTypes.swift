import Foundation

/// A JSON-like argument value passed to a tool. Modeled explicitly (rather
/// than reaching for `Any`/`[String: Any]`) so the whole call path stays
/// `Sendable` and equatable, which matters once arguments cross actor
/// boundaries between a provider and the router.
public indirect enum LLMToolArgumentValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LLMToolArgumentValue])
    case object([String: LLMToolArgumentValue])
    case null
}

/// Declares a tool's name, description, and argument schema so a provider
/// can decide when and how to call it. `parameterSchema` is deliberately a
/// loose `[String: LLMToolArgumentValue]` rather than a typed JSON Schema
/// model — providers in this library are simulated, and a full JSON Schema
/// implementation would add weight without adding to the architectural
/// story this repo is telling.
public struct LLMToolDefinition: Sendable, Equatable {
    public let name: String
    public let toolDescription: String
    public let parameterSchema: [String: LLMToolArgumentValue]

    public init(
        name: String,
        toolDescription: String,
        parameterSchema: [String: LLMToolArgumentValue] = [:]
    ) {
        self.name = name
        self.toolDescription = toolDescription
        self.parameterSchema = parameterSchema
    }
}

/// A provider's request to invoke a specific tool with specific arguments.
public struct ToolCallRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let toolName: String
    public let arguments: [String: LLMToolArgumentValue]

    public init(id: String = UUID().uuidString, toolName: String, arguments: [String: LLMToolArgumentValue]) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }
}

/// The outcome of actually executing a `ToolCallRequest`.
public enum LLMToolResult: Sendable, Equatable {
    case success(String)
    case failure(String)

    /// Text handed back to the provider as a `.tool` message so it can
    /// continue the conversation, regardless of whether execution
    /// succeeded — a failed tool call is still valid conversational
    /// input, not a transport-level error.
    public var messageContent: String {
        switch self {
        case .success(let text): return text
        case .failure(let reason): return "Tool call failed: \(reason)"
        }
    }
}
