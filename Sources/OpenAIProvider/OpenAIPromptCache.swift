import Foundation
import AISDKProvider
import AISDKProviderUtils

public enum OpenAIPromptCacheMode: String, Sendable, Equatable {
    case implicit
    case explicit
}

public enum OpenAIPromptCacheTTL: String, Sendable, Equatable {
    case thirtyMinutes = "30m"
    case twelveHours = "12h"
}

public struct OpenAIPromptCacheOptions: Sendable, Equatable {
    public var mode: OpenAIPromptCacheMode?
    public var ttl: OpenAIPromptCacheTTL?
    public var prewarm: Bool?
    public var comparisonResponseId: String?

    public init(
        mode: OpenAIPromptCacheMode? = nil,
        ttl: OpenAIPromptCacheTTL? = nil,
        prewarm: Bool? = nil,
        comparisonResponseId: String? = nil
    ) {
        self.mode = mode
        self.ttl = ttl
        self.prewarm = prewarm
        self.comparisonResponseId = comparisonResponseId
    }

    var jsonValue: JSONValue {
        var value: [String: JSONValue] = [:]
        if let mode {
            value["mode"] = .string(mode.rawValue)
        }
        if let ttl {
            value["ttl"] = .string(ttl.rawValue)
        }
        if let prewarm { value["prewarm"] = .bool(prewarm) }
        if let comparisonResponseId { value["comparison_response_id"] = .string(comparisonResponseId) }
        return .object(value)
    }
}

func parseOpenAIPromptCacheOptions(
    _ value: JSONValue?,
    vendor: String = "openai",
    supportsResponsesControls: Bool = false
) throws -> OpenAIPromptCacheOptions? {
    guard let value, value != .null else {
        return nil
    }
    guard case .object(let object) = value else {
        throw TypeValidationError.wrap(
            value: value,
            cause: SchemaValidationIssuesError(vendor: vendor, issues: "promptCacheOptions must be an object")
        )
    }

    var result = OpenAIPromptCacheOptions()
    if let modeValue = object["mode"] {
        guard case .string(let rawMode) = modeValue,
              let mode = OpenAIPromptCacheMode(rawValue: rawMode) else {
            throw TypeValidationError.wrap(
                value: modeValue,
                cause: SchemaValidationIssuesError(vendor: vendor, issues: "promptCacheOptions.mode must be one of implicit, explicit")
            )
        }
        result.mode = mode
    }
    if let ttlValue = object["ttl"] {
        guard case .string(let rawTTL) = ttlValue,
              let ttl = OpenAIPromptCacheTTL(rawValue: rawTTL) else {
            throw TypeValidationError.wrap(
                value: ttlValue,
                cause: SchemaValidationIssuesError(vendor: vendor, issues: "promptCacheOptions.ttl must be one of 30m, 12h")
            )
        }
        result.ttl = ttl
    }

    if let prewarmValue = object["prewarm"] {
        guard case .bool(let prewarm) = prewarmValue else {
            throw TypeValidationError.wrap(value: prewarmValue,
                cause: SchemaValidationIssuesError(vendor: vendor, issues: "promptCacheOptions.prewarm must be boolean"))
        }
        result.prewarm = prewarm
    }
    if let comparisonValue = object["comparisonResponseId"], comparisonValue != .null {
        guard case .string(let comparison) = comparisonValue,
              !comparison.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TypeValidationError.wrap(value: comparisonValue,
                cause: SchemaValidationIssuesError(vendor: vendor, issues: "promptCacheOptions.comparisonResponseId must be a nonempty string"))
        }
        result.comparisonResponseId = comparison
    }
    if !supportsResponsesControls,
       result.ttl == .twelveHours || result.prewarm != nil || result.comparisonResponseId != nil {
        throw TypeValidationError.wrap(value: value,
            cause: SchemaValidationIssuesError(vendor: vendor, issues: "12h, prewarm and comparisonResponseId require the Responses API"))
    }

    return result
}

func openAIPromptCacheBreakpoint(
    from providerOptions: SharedV3ProviderOptions?,
    providerOptionsName: String = "openai"
) -> JSONValue? {
    guard case .object(let breakpoint)? = providerOptions?[providerOptionsName]?["promptCacheBreakpoint"],
          breakpoint["mode"] == .string("explicit") else {
        return nil
    }
    return .object(breakpoint)
}
