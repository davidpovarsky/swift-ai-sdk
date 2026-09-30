import Foundation
import Testing
@testable import AISDKProvider
@testable import AISDKProviderUtils
@testable import OpenAICompatibleProvider

@Suite("OpenAI-compatible reasoning_details preservation")
struct OpenAICompatibleReasoningDetailsTests {
    private let prompt: LanguageModelV4Prompt = [
        .user(
            content: [.text(LanguageModelV4TextPart(text: "Hello"))],
            providerOptions: nil
        )
    ]

    private static let richOpaqueReasoningDetails: JSONValue = .array([
        .object([
            "type": .string("reasoning.text"),
            "text": .string("opaque-a"),
            "signature": .string("sig-A"),
            "provider_blob": .object([
                "encrypted": .string("ENC-AAA"),
                "index": .number(7),
                "valid": .bool(true),
                "nullable": .null
            ])
        ]),
        .object([
            "type": .string("provider.custom"),
            "signature": .string("sig-B"),
            "payload": .array([
                .string("x"),
                .number(3),
                .bool(false),
                .object(["nested": .string("value")])
            ])
        ])
    ])

    private func makeHTTPResponse(url: URL, contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    @Test("reasoning_details in V4 assistant message is hoisted to top-level with exact structural equality")
    func testReasoningDetailsV4Hoisting() throws {
        let details = Self.richOpaqueReasoningDetails

        let prompt: LanguageModelV4Prompt = [
            .assistant(
                content: [
                    .reasoning(LanguageModelV4ReasoningPart(
                        text: "Thinking process",
                        providerOptions: [
                            "hanlin-openai-compatible": ["reasoning_details": details]
                        ]
                    )),
                    .toolCall(LanguageModelV4ToolCallPart(
                        toolCallId: "call-1",
                        toolName: "calc",
                        input: .object(["x": .number(1)])
                    ))
                ],
                providerOptions: nil
            )
        ]

        let messages = try convertToOpenAICompatibleChatMessages(prompt: prompt)
        #expect(messages.count == 1)
        guard case .object(let obj) = messages[0] else {
            Issue.record("Expected object message")
            return
        }

        #expect(obj["role"] == .string("assistant"))
        #expect(obj["reasoning_content"] == .string("Thinking process"))
        #expect(obj["reasoning_details"] == details)
        #expect(obj["tool_calls"] != nil)
        // Ensure reasoning_details is not placed inside tool_calls
        if case .array(let tools) = obj["tool_calls"] {
            for tool in tools {
                if case .object(let toolObj) = tool {
                    #expect(toolObj["reasoning_details"] == nil)
                }
            }
        }
    }

    @Test("doGenerate preserves reasoning_details in providerMetadata with exact structural equality")
    func testDoGeneratePreservesReasoningDetails() async throws {
        let expectedDetails = Self.richOpaqueReasoningDetails
        let encodedData = try JSONEncoder().encode(expectedDetails)
        let detailsJSONObject = try JSONSerialization.jsonObject(with: encodedData)

        let generateResponse: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "Done",
                    "reasoning_content": "Plan step",
                    "reasoning_details": detailsJSONObject
                ],
                "finish_reason": "stop"
            ]]
        ]
        let generateData = try JSONSerialization.data(withJSONObject: generateResponse)
        let url = URL(string: "https://api.example.com/chat/completions")!

        let fetch: FetchFunction = { _ in
            FetchResponse(
                body: .data(generateData),
                urlResponse: self.makeHTTPResponse(url: url, contentType: "application/json")
            )
        }

        let provider = createOpenAICompatible(settings: .init(
            baseURL: "https://api.example.com",
            name: "test-provider",
            fetch: fetch
        ))
        let model = try provider.languageModel(modelId: "chat-model")
        let result = try await model.doGenerate(options: .init(prompt: prompt))

        let reasoningParts = result.content.compactMap { content -> LanguageModelV4Reasoning? in
            guard case .reasoning(let reasoning) = content else { return nil }
            return reasoning
        }
        #expect(reasoningParts.count == 1)
        #expect(reasoningParts[0].text == "Plan step")
        let meta = reasoningParts[0].providerMetadata?["test-provider"]
        let capturedDetails = meta?["reasoning_details"]
        #expect(capturedDetails == expectedDetails)

        let metaCompat = reasoningParts[0].providerMetadata?["openaiCompatible"]
        #expect(metaCompat?["reasoning_details"] == expectedDetails)
    }

    @Test("doStream preserves reasoning_details in reasoningEnd providerMetadata with exact structural equality")
    func testDoStreamPreservesReasoningDetails() async throws {
        let expectedDetails = Self.richOpaqueReasoningDetails
        let encodedData = try JSONEncoder().encode(expectedDetails)
        let detailsJSONObject = try JSONSerialization.jsonObject(with: encodedData)

        let streamEventDict: [String: Any] = [
            "choices": [[
                "delta": [
                    "role": "assistant",
                    "reasoning_content": "Plan step",
                    "reasoning_details": detailsJSONObject
                ],
                "finish_reason": NSNull()
            ]]
        ]
        let streamEventData = try JSONSerialization.data(withJSONObject: streamEventDict)
        let streamEventString = String(decoding: streamEventData, as: UTF8.self)
        let finishEvent = #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
        let url = URL(string: "https://api.example.com/chat/completions")!

        let fetch: FetchFunction = { _ in
            FetchResponse(
                body: .stream(AsyncThrowingStream { continuation in
                    continuation.yield(Data("data: \(streamEventString)\n\n".utf8))
                    continuation.yield(Data("data: \(finishEvent)\n\n".utf8))
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                }),
                urlResponse: self.makeHTTPResponse(url: url, contentType: "text/event-stream")
            )
        }

        let provider = createOpenAICompatible(settings: .init(
            baseURL: "https://api.example.com",
            name: "test-provider",
            fetch: fetch
        ))
        let model = try provider.languageModel(modelId: "chat-model")
        let streamed = try await model.doStream(options: .init(prompt: prompt))

        var capturedMetadata: SharedV4ProviderMetadata? = nil
        var textDeltas: [String] = []
        var reasoningDeltas: [String] = []
        for try await part in streamed.stream {
            switch part {
            case .reasoningDelta(_, let delta, _):
                reasoningDeltas.append(delta)
            case .reasoningEnd(_, let providerMetadata):
                capturedMetadata = providerMetadata
            case .textDelta(_, let delta, _):
                textDeltas.append(delta)
            default:
                break
            }
        }

        #expect(reasoningDeltas.joined() == "Plan step")
        #expect(textDeltas.joined() == "Hi")
        let meta = capturedMetadata?["test-provider"]
        #expect(meta?["reasoning_details"] == expectedDetails)

        let metaCompat = capturedMetadata?["openaiCompatible"]
        #expect(metaCompat?["reasoning_details"] == expectedDetails)
    }

    @Test("Full SDK continuation round-trip: stream response -> reasoningEnd metadata -> next prompt -> convertToOpenAICompatibleChatMessages preserves exact reasoning_details")
    func testFullContinuationRoundTripPreservesExactReasoningDetails() async throws {
        let expectedDetails = Self.richOpaqueReasoningDetails
        let encodedData = try JSONEncoder().encode(expectedDetails)
        let detailsJSONObject = try JSONSerialization.jsonObject(with: encodedData)

        // 1. Mock OpenRouter streaming response emitting reasoning_details + tool call
        let toolCallDict: [String: Any] = [
            "index": 0,
            "id": "call-roundtrip-1",
            "type": "function",
            "function": [
                "name": "calc",
                "arguments": "{\"x\":1}"
            ]
        ]
        let streamChunk1: [String: Any] = [
            "choices": [[
                "delta": [
                    "role": "assistant",
                    "reasoning_content": "Deep reasoning before tool call",
                    "reasoning_details": detailsJSONObject,
                    "tool_calls": [toolCallDict]
                ],
                "finish_reason": NSNull()
            ]]
        ]
        let chunk1Data = try JSONSerialization.data(withJSONObject: streamChunk1)
        let chunk1Str = String(decoding: chunk1Data, as: UTF8.self)

        let termChunk = #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
        let url = URL(string: "https://api.example.com/chat/completions")!

        let fetch: FetchFunction = { _ in
            FetchResponse(
                body: .stream(AsyncThrowingStream { continuation in
                    continuation.yield(Data("data: \(chunk1Str)\n\n".utf8))
                    continuation.yield(Data("data: \(termChunk)\n\n".utf8))
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                }),
                urlResponse: self.makeHTTPResponse(url: url, contentType: "text/event-stream")
            )
        }

        let provider = createOpenAICompatible(settings: .init(
            baseURL: "https://api.example.com",
            name: "test-provider",
            fetch: fetch
        ))
        let model = try provider.languageModel(modelId: "chat-model")
        let streamed = try await model.doStream(options: .init(prompt: prompt))

        var capturedReasoningMetadata: SharedV4ProviderMetadata? = nil
        var capturedReasoningText = ""
        var capturedToolCalls: [LanguageModelV4ToolCallPart] = []

        for try await part in streamed.stream {
            switch part {
            case .reasoningDelta(_, let delta, _):
                capturedReasoningText += delta
            case .reasoningEnd(_, let metadata):
                capturedReasoningMetadata = metadata
            case .toolCall(let toolCall):
                capturedToolCalls.append(LanguageModelV4ToolCallPart(
                    toolCallId: toolCall.toolCallId,
                    toolName: toolCall.toolName,
                    input: toolCall.input
                ))
            default:
                break
            }
        }

        #expect(capturedReasoningText == "Deep reasoning before tool call")
        #expect(capturedToolCalls.count == 1)
        #expect(capturedToolCalls[0].toolCallId == "call-roundtrip-1")
        #expect(capturedReasoningMetadata?["test-provider"]?["reasoning_details"] == expectedDetails)

        // 2. Build the continuation prompt for the next model turn using captured metadata
        // Test with test-provider metadata as well as Hanlin's "hanlin-openai-compatible" namespace
        for providerNamespace in ["test-provider", "openaiCompatible", "hanlin-openai-compatible"] {
            let providerOptions: SharedV4ProviderOptions = [
                providerNamespace: ["reasoning_details": expectedDetails]
            ]

            let continuationPrompt: LanguageModelV4Prompt = [
                .user(
                    content: [.text(LanguageModelV4TextPart(text: "Hello"))],
                    providerOptions: nil
                ),
                .assistant(
                    content: [
                        .reasoning(LanguageModelV4ReasoningPart(
                            text: capturedReasoningText,
                            providerOptions: providerOptions
                        )),
                        .toolCall(capturedToolCalls[0])
                    ],
                    providerOptions: nil
                ),
                .tool(
                    content: [
                        .toolResult(LanguageModelV4ToolResultPart(
                            toolCallId: "call-roundtrip-1",
                            toolName: "calc",
                            output: .text("2")
                        ))
                    ],
                    providerOptions: nil
                )
            ]

            // 3. Convert prompt to OpenAI-compatible chat messages
            let outgoingMessages = try convertToOpenAICompatibleChatMessages(prompt: continuationPrompt)
            #expect(outgoingMessages.count == 3)

            guard case .object(let assistantObj) = outgoingMessages[1] else {
                Issue.record("Expected assistant object at index 1 for namespace \(providerNamespace)")
                continue
            }

            // Assert exact structural equality
            #expect(assistantObj["role"] == .string("assistant"))
            #expect(assistantObj["reasoning_content"] == .string("Deep reasoning before tool call"))
            #expect(assistantObj["reasoning_details"] == expectedDetails)

            // Verify reasoning_details is at the top-level of assistant message and NOT inside tool_calls
            guard case .array(let toolCallsArray) = assistantObj["tool_calls"] else {
                Issue.record("Expected tool_calls array in assistant message")
                continue
            }
            #expect(toolCallsArray.count == 1)
            for toolCallVal in toolCallsArray {
                guard case .object(let toolCallObj) = toolCallVal else {
                    Issue.record("Expected object for tool call")
                    continue
                }
                #expect(toolCallObj["reasoning_details"] == nil, "reasoning_details must NOT be inside tool_calls")
            }
        }
    }
}
