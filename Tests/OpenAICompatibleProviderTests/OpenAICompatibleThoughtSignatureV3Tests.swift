import Foundation
import Testing
import AISDKProvider
import AISDKProviderUtils
@testable import OpenAICompatibleProvider

@Suite("OpenAI-compatible V3 thought signatures")
struct OpenAICompatibleThoughtSignatureV3Tests {
    enum Signature: String, CaseIterable, Sendable {
        case absent, empty, opaque

        var value: String? {
            switch self {
            case .absent: return nil
            case .empty: return ""
            case .opaque: return " opaque+/==\nעברית \"quoted\" e\u{301} "
            }
        }

        var expectedMetadata: SharedV3ProviderMetadata? {
            guard let value, !value.isEmpty else { return nil }
            return ["google": ["thoughtSignature": .string(value)]]
        }
    }

    private let prompt: LanguageModelV3Prompt = [
        .user(content: [.text(.init(text: "Look up a source."))], providerOptions: nil)
    ]

    private func call(
        index: Int = 0,
        id: String? = "call-1",
        name: String? = "lookup",
        arguments: String? = "{}",
        signature: String? = nil
    ) -> JSONValue {
        var function: [String: JSONValue] = [:]
        if let name { function["name"] = .string(name) }
        if let arguments { function["arguments"] = .string(arguments) }
        var value: [String: JSONValue] = [
            "index": .number(Double(index)),
            "type": .string("function"),
            "function": .object(function)
        ]
        if let id { value["id"] = .string(id) }
        if let signature {
            value["extra_content"] = .object([
                "google": .object(["thought_signature": .string(signature)])
            ])
        }
        return .object(value)
    }

    private func event(_ calls: [JSONValue], finish: String? = nil) -> JSONValue {
        .object(["choices": .array([.object([
            "delta": .object(["tool_calls": .array(calls)]),
            "finish_reason": finish.map(JSONValue.string) ?? .null
        ])])])
    }

    private func model(
        response: JSONValue? = nil,
        events: [JSONValue] = [],
        providerName: String = "hanlin-openai-compatible"
    ) throws -> any LanguageModelV3 {
        let url = URL(string: "https://api.example.com/chat/completions")!
        let responseData = try response.map { try JSONEncoder().encode($0) }
        let chunks = try events.map {
            Data(("data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n").utf8)
        }
        let fetch: FetchFunction = { _ in
            if let responseData {
                return FetchResponse(
                    body: .data(responseData),
                    urlResponse: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!
                )
            }
            return FetchResponse(
                body: .stream(AsyncThrowingStream { continuation in
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                }),
                urlResponse: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"])!
            )
        }
        return try createOpenAICompatibleProvider(settings: .init(
            baseURL: "https://api.example.com", name: providerName, fetch: fetch
        )).languageModel(modelId: "test-model")
    }

    private func outgoingCalls(_ calls: [LanguageModelV3ToolCall]) throws -> [JSONValue] {
        let parts = try calls.map { call in
            LanguageModelV3MessagePart.toolCall(LanguageModelV3ToolCallPart(
                toolCallId: call.toolCallId, toolName: call.toolName,
                input: try JSONDecoder().decode(JSONValue.self, from: Data(call.input.utf8)),
                providerOptions: call.providerMetadata
            ))
        }
        let messages = try convertToOpenAICompatibleChatMessages(prompt: [
            LanguageModelV3Message.assistant(content: parts, providerOptions: nil)
        ])
        guard case .object(let message) = try #require(messages.first),
              case .array(let toolCalls)? = message["tool_calls"] else {
            Issue.record("The original V3 converter did not return tool calls.")
            return []
        }
        return toolCalls
    }

    private func wireSignatureBytes(_ call: JSONValue) -> [UInt8]? {
        guard case .object(let payload) = call,
              case .object(let extra)? = payload["extra_content"],
              case .object(let google)? = extra["google"],
              case .string(let signature)? = google["thought_signature"] else { return nil }
        return Array(signature.utf8)
    }

    private func expectedWireCall(id: String, name: String, signature: String?) -> JSONValue {
        var payload: [String: JSONValue] = [
            "type": .string("function"), "id": .string(id),
            "function": .object(["name": .string(name), "arguments": .string("{}")])
        ]
        if let signature, !signature.isEmpty {
            payload["extra_content"] = .object([
                "google": .object(["thought_signature": .string(signature)])
            ])
        }
        return .object(payload)
    }

    @Test("V3 nonstream receipt retains only a real nonempty Google signature", arguments: Signature.allCases)
    func nonstreamReceipt(signature: Signature) async throws {
        let response: JSONValue = .object(["choices": .array([.object([
            "message": .object(["tool_calls": .array([call(signature: signature.value)])]),
            "finish_reason": .string("stop")
        ])])])
        let result = try await model(response: response).doGenerate(options: .init(prompt: prompt))
        let calls = result.content.compactMap { part -> LanguageModelV3ToolCall? in
            guard case .toolCall(let call) = part else { return nil }
            return call
        }
        try #require(calls.count == 1)
        #expect(calls[0].providerMetadata == signature.expectedMetadata)
        #expect(result.finishReason.unified == .stop)
        let outgoing = try outgoingCalls(calls)
        #expect(outgoing == [expectedWireCall(id: "call-1", name: "lookup", signature: signature.value)])
        let expectedBytes = signature.value.flatMap { $0.isEmpty ? nil : Array($0.utf8) }
        #expect(outgoing.map(wireSignatureBytes) == [expectedBytes])
    }

    @Test("V3 stream receipt keeps the generic provider name independent of signature identity", arguments: Signature.allCases)
    func streamReceipt(signature: Signature) async throws {
        let result = try await model(
            events: [event([call(signature: signature.value)], finish: "stop")],
            providerName: "arbitrary-compatible-provider"
        ).doStream(options: .init(prompt: prompt))
        let parts = try await convertReadableStreamToArray(result.stream)
        let calls = parts.compactMap { part -> LanguageModelV3ToolCall? in
            guard case .toolCall(let call) = part else { return nil }
            return call
        }
        try #require(calls.count == 1)
        #expect(calls[0].providerMetadata == signature.expectedMetadata)
        let outgoing = try outgoingCalls(calls)
        #expect(outgoing == [expectedWireCall(id: "call-1", name: "lookup", signature: signature.value)])
        let expectedBytes = signature.value.flatMap { $0.isEmpty ? nil : Array($0.utf8) }
        #expect(outgoing.map(wireSignatureBytes) == [expectedBytes])
    }

    @Test("Late metadata after complete JSON stays on its own parallel call and duplicates are harmless")
    func lateParallelSignatures() async throws {
        let first = "first+/=="
        let second = "second opaque signature"
        let result = try await model(events: [
            event([
                call(index: 0, id: "first", name: "lookup"),
                call(index: 1, id: "second", name: "lookup", signature: second),
                call(index: 2, id: "unsigned", name: "lookup")
            ]),
            event([call(index: 0, id: nil, name: nil, arguments: nil, signature: first)]),
            event([call(index: 0, id: nil, name: nil, arguments: nil, signature: first)], finish: "stop")
        ]).doStream(options: .init(prompt: prompt))
        let parts = try await convertReadableStreamToArray(result.stream)
        let calls = parts.compactMap { part -> LanguageModelV3ToolCall? in
            guard case .toolCall(let call) = part else { return nil }
            return call
        }
        #expect(calls.map(\.toolCallId) == ["first", "second", "unsigned"])
        #expect(try outgoingCalls(calls) == [
            expectedWireCall(id: "first", name: "lookup", signature: first),
            expectedWireCall(id: "second", name: "lookup", signature: second),
            expectedWireCall(id: "unsigned", name: "lookup", signature: nil)
        ])
    }

    @Test("Conflicting signatures on one streamed call fail before a completed call is emitted",
        arguments: ["different signature", "e\u{301}"])
    func conflictingSignaturesFail(conflicting: String) async throws {
        let result = try await model(events: [
            event([call(signature: "\u{e9}")]),
            event([call(id: nil, name: nil, arguments: nil, signature: conflicting)], finish: "stop")
        ]).doStream(options: .init(prompt: prompt))
        var completedCalls = 0
        var caught = false
        do {
            for try await part in result.stream {
                if case .toolCall = part { completedCalls += 1 }
            }
        } catch let error as InvalidResponseDataError {
            caught = true
            #expect(error.message == "Conflicting thought signatures for the same tool call.")
        }
        #expect(caught)
        #expect(completedCalls == 0)
    }

    @Test("V3 does not coerce nonstring values into a signature", arguments: [
        JSONValue.null, .bool(true), .number(1), .array([.string("signature")]), .object([:])
    ])
    func nonstringMetadataIsNotASignature(value: JSONValue) throws {
        let messages = try convertToOpenAICompatibleChatMessages(prompt: [
            LanguageModelV3Message.assistant(content: [
                .toolCall(.init(
                    toolCallId: "call-1", toolName: "lookup", input: .object([:]),
                    providerOptions: ["google": ["thoughtSignature": value]]
                ))
            ], providerOptions: nil)
        ])
        guard case .object(let message) = try #require(messages.first),
              case .array(let calls)? = message["tool_calls"] else {
            Issue.record("Missing original tool-call payload.")
            return
        }
        #expect(calls == [expectedWireCall(id: "call-1", name: "lookup", signature: nil)])
    }
}
