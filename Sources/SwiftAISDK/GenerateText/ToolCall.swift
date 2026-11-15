import Foundation
import AISDKProvider
import AISDKProviderUtils

/**
 Tool call types for generation results.

 Port of `@ai-sdk/ai/src/generate-text/tool-call.ts`.

 **Swift adaptation**: TypeScript uses mapped types with `ValueOf` utility to create
 a union of all possible tool calls. Swift uses an enum with associated values instead,
 as Swift doesn't have the same type-level programming capabilities.
 */

/// Static tool call with known tool name and typed input.
/// Represents a tool call where the tool is known at compile time.
public struct StaticToolCall: Sendable {
    /// Type discriminator.
    public let type: String = "tool-call"

    /// The ID of the tool call.
    public let toolCallId: String

    /// The name of the tool that was called.
    public let toolName: String

    /// Optional display title for the tool.
    public let title: String?

    /// The input/arguments for the tool call.
    public let input: JSONValue

    /// Original accepted JSON; nil when unavailable. Not authorization.
    public let rawInput: ToolCallRawInput?

    /// Whether the tool was executed by the provider.
    public let providerExecuted: Bool?

    /// Additional provider-specific metadata.
    public let providerMetadata: ProviderMetadata?

    /// Whether this is a dynamic tool call.
    /// For StaticToolCall, this is always false or nil.
    public let dynamic: Bool?

    /// Whether this tool call is invalid (unparsable or tool doesn't exist).
    /// For StaticToolCall, this is always false or nil.
    public let invalid: Bool?

    public init(
        toolCallId: String,
        toolName: String,
        title: String? = nil,
        input: JSONValue,
        providerExecuted: Bool? = nil,
        providerMetadata: ProviderMetadata? = nil,
        rawInput: ToolCallRawInput? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.title = title
        self.input = input
        self.rawInput = rawInput
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.dynamic = false
        self.invalid = false
    }
}

/// Dynamic tool call with unknown tool name or input type.
/// Represents a tool call where the tool is determined at runtime.
public struct DynamicToolCall: Sendable {
    /// Type discriminator.
    public let type: String = "tool-call"

    /// The ID of the tool call.
    public let toolCallId: String

    /// The name of the tool that was called.
    public let toolName: String

    /// Optional display title for the tool.
    public let title: String?

    /// The input/arguments for the tool call.
    public let input: JSONValue

    /// Original accepted JSON; nil when unavailable. Not authorization.
    public let rawInput: ToolCallRawInput?

    /// Whether this is a dynamic tool call.
    /// For DynamicToolCall, this is always true.
    public let dynamic: Bool = true

    /// Whether the tool was executed by the provider.
    public let providerExecuted: Bool?

    /// Additional provider-specific metadata.
    public let providerMetadata: ProviderMetadata?

    /// True if this is caused by an unparsable tool call or
    /// a tool that does not exist.
    ///
    /// TODO AI SDK 6: separate into a new InvalidToolCall type
    public let invalid: Bool?

    /// The error that caused the tool call to be invalid.
    ///
    /// TODO AI SDK 6: separate into a new InvalidToolCall type
    public let error: (any Error)?

    public init(
        toolCallId: String,
        toolName: String,
        title: String? = nil,
        input: JSONValue,
        providerExecuted: Bool? = nil,
        providerMetadata: ProviderMetadata? = nil,
        invalid: Bool? = nil,
        error: (any Error)? = nil,
        rawInput: ToolCallRawInput? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.title = title
        self.input = input
        self.rawInput = rawInput
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.invalid = invalid
        self.error = error
    }
}

/// A tool call that can be either static (typed) or dynamic (untyped).
public enum TypedToolCall: Sendable {
    /// A static tool call with known tool name and typed input.
    case `static`(StaticToolCall)

    /// A dynamic tool call with unknown tool name or input type.
    case dynamic(DynamicToolCall)

    /// The ID of the tool call.
    public var toolCallId: String {
        switch self {
        case .static(let call): return call.toolCallId
        case .dynamic(let call): return call.toolCallId
        }
    }

    /// The name of the tool that was called.
    public var toolName: String {
        switch self {
        case .static(let call): return call.toolName
        case .dynamic(let call): return call.toolName
        }
    }

    /// The input/arguments for the tool call.
    public var input: JSONValue {
        switch self {
        case .static(let call): return call.input
        case .dynamic(let call): return call.input
        }
    }

    public var rawInput: ToolCallRawInput? {
        switch self {
        case .static(let call): call.rawInput
        case .dynamic(let call): call.rawInput
        }
    }

    /// Optional display title for the tool.
    public var title: String? {
        switch self {
        case .static(let call): return call.title
        case .dynamic(let call): return call.title
        }
    }

    /// Whether the tool was executed by the provider.
    public var providerExecuted: Bool? {
        switch self {
        case .static(let call): return call.providerExecuted
        case .dynamic(let call): return call.providerExecuted
        }
    }

    /// Additional provider-specific metadata.
    public var providerMetadata: ProviderMetadata? {
        switch self {
        case .static(let call): return call.providerMetadata
        case .dynamic(let call): return call.providerMetadata
        }
    }

    /// Whether this is a dynamic tool call.
    public var isDynamic: Bool {
        switch self {
        case .static: return false
        case .dynamic: return true
        }
    }

    /// Whether this tool call is invalid.
    public var invalid: Bool? {
        switch self {
        case .static(let call): return call.invalid
        case .dynamic(let call): return call.invalid
        }
    }

    /// The error that caused the tool call to be invalid (for dynamic calls only).
    public var error: (any Error)? {
        switch self {
        case .static: return nil
        case .dynamic(let call): return call.error
        }
    }
}

/// Revalidate persisted provenance against the current tool before local execution.
/// Parsing/schema transforms must agree with the normalized input. This check is
/// deliberately independent of consent, cancellation, and host authority checks.
func validatedToolCallRawInput(_ call: TypedToolCall, tool: Tool) async throws -> ToolCallRawInput? {
    try Task.checkCancellation()
    guard call.invalid != true else { throw RawToolInputError.invalid }
    guard let raw = call.rawInput else { return nil }
    guard raw.toolCallId == call.toolCallId, raw.toolName == call.toolName,
          raw.json.utf8.count <= ToolCallRawInput.maximumUTF8Bytes,
          call.isDynamic == (tool.type == .dynamic) else { throw RawToolInputError.invalid }
    let parsed = await safeParseJSON(ParseJSONOptions(text: raw.json))
    guard case .success(let original, _) = parsed, original == call.input else {
        throw RawToolInputError.invalid
    }
    let validated = await safeValidateTypes(ValidateTypesOptions(value: original, schema: tool.inputSchema))
    try Task.checkCancellation()
    guard case .success(let accepted, _) = validated, accepted == original else {
        throw RawToolInputError.invalid
    }
    return raw
}

enum RawToolInputError: Error, LocalizedError {
    case invalid
    var errorDescription: String? { "Tool input provenance is invalid or no longer matches the current tool schema." }
}
