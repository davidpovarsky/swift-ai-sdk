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

    private func makeHTTPResponse(url: URL, contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    @Test("reasoning_details in V4 assistant message is hoisted to top-level")
    func testReasoningDetailsV4Hoisting() throws {
        let details: JSONValue = .array([
            .object([
                "type": .string("reasoning.text"),
                "text": .string("Plan step 1"),
                "signature": .string("sig-123")
            ])
        ])

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

    @Test("doGenerate preserves reasoning_details in providerMetadata")
    func testDoGeneratePreservesReasoningDetails() async throws {
        let details: [[String: Any]] = [
            [
                "type": "reasoning.text",
                "text": "Plan",
                "signature": "sig-gen-456"
            ]
        ]
        let generateResponse: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "Done",
                    "reasoning_content": "Plan",
                    "reasoning_details": details
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
        let meta = reasoningParts[0].providerMetadata?["test-provider"]
        #expect(meta?["reasoning_details"] != nil)
    }

    @Test("doStream preserves reasoning_details in reasoningEnd providerMetadata")
    func testDoStreamPreservesReasoningDetails() async throws {
        let streamEvent = #"{"choices":[{"delta":{"role":"assistant","reasoning_content":"Plan","reasoning_details":[{"type":"reasoning.text","text":"Plan","signature":"sig-stream-789"}]},"finish_reason":null}]}"#
        let finishEvent = #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
        let url = URL(string: "https://api.example.com/chat/completions")!

        let fetch: FetchFunction = { _ in
            FetchResponse(
                body: .stream(AsyncThrowingStream { continuation in
                    continuation.yield(Data("data: \(streamEvent)\n\n".utf8))
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
        for try await part in streamed.stream {
            if case .reasoningEnd(_, let providerMetadata) = part {
                capturedMetadata = providerMetadata
            }
        }

        let meta = capturedMetadata?["test-provider"]
        #expect(meta?["reasoning_details"] != nil)
    }
}
