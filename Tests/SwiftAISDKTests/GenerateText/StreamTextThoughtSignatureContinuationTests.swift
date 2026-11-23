import Foundation
import Testing
import AISDKProvider
import AISDKProviderUtils
import OpenAICompatibleProvider
@testable import SwiftAISDK

@Suite("StreamText OpenAI-compatible signed tool continuation")
struct StreamTextThoughtSignatureContinuationTests {
    private actor Capture {
        private var bodies: [Data] = []
        private var executions: [String] = []

        func request(_ body: Data) -> Int {
            bodies.append(body)
            return bodies.count - 1
        }
        func executed(_ name: String) { executions.append(name) }
        func requests() -> [Data] { bodies }
        func toolExecutions() -> [String] { executions }
    }

    private enum FixtureError: Error { case unexpectedRequest }

    private func event(_ delta: [String: JSONValue], finish: String? = nil) -> JSONValue {
        .object(["choices": .array([.object([
            "index": .number(0),
            "delta": .object(delta),
            "finish_reason": finish.map(JSONValue.string) ?? .null
        ])])])
    }

    private func toolCall(
        id: String? = nil, name: String? = nil, arguments: String? = nil,
        signature: String? = nil
    ) -> JSONValue {
        var function: [String: JSONValue] = [:]
        if let name { function["name"] = .string(name) }
        if let arguments { function["arguments"] = .string(arguments) }
        var call: [String: JSONValue] = [
            "index": .number(0), "type": .string("function"), "function": .object(function)
        ]
        if let id { call["id"] = .string(id) }
        if let signature {
            call["extra_content"] = .object([
                "google": .object(["thought_signature": .string(signature)])
            ])
        }
        return .object(call)
    }

    private func streamBytes(_ events: [JSONValue]) throws -> [Data] {
        try events.map {
            Data(("data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n").utf8)
        } + [Data("data: [DONE]\n\n".utf8)]
    }

    private func requestMessages(_ data: Data) throws -> [[String: JSONValue]] {
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let messages)? = body["messages"] else {
            Issue.record("The real provider fetch did not receive a messages array.")
            return []
        }
        return try messages.map { message in
            guard case .object(let value) = message else {
                throw FixtureError.unexpectedRequest
            }
            return value
        }
    }

    private func assistantCalls(_ messages: [[String: JSONValue]]) -> [JSONValue] {
        messages.flatMap { message in
            guard message["role"] == .string("assistant"),
                  case .array(let calls)? = message["tool_calls"] else { return [JSONValue]() }
            return calls
        }
    }

    private func wireSignatureBytes(_ call: JSONValue) -> [UInt8]? {
        guard case .object(let payload) = call,
              case .object(let extra)? = payload["extra_content"],
              case .object(let google)? = extra["google"],
              case .string(let signature)? = google["thought_signature"] else { return nil }
        return Array(signature.utf8)
    }

    private func expectedCall(id: String, name: String, query: String, signature: String) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("function"),
            "function": .object([
                "name": .string(name), "arguments": .string("{\"query\":\"\(query)\"}")
            ]),
            "extra_content": .object([
                "google": .object(["thought_signature": .string(signature)])
            ])
        ])
    }

    @Test("Original streamText sends exact signatures and tool results on both later requests after finish stop")
    func signedSequentialContinuation() async throws {
        let firstSignature = " first+/==\nעברית \"opaque\" e\u{301} "
        let secondSignature = "second+/== opaque value"
        let capture = Capture()
        let responses = try [
            streamBytes([
                event(["role": .string("assistant"), "tool_calls": .array([
                    toolCall(id: "search-call", name: "search", arguments: #"{"query":"source"}"#)
                ])]),
                // JSON is already complete. The actual tracker must still accept
                // metadata in this later delta before its one flush emission.
                event(["tool_calls": .array([toolCall(signature: firstSignature)])], finish: "stop")
            ]),
            streamBytes([
                event(["role": .string("assistant"), "tool_calls": .array([
                    toolCall(id: "reference-call", name: "resolve",
                        arguments: #"{"query":"reference"}"#, signature: secondSignature)
                ])], finish: "stop")
            ]),
            streamBytes([
                event(["role": .string("assistant"), "content": .string("English and עברית answer.")],
                    finish: "stop")
            ])
        ]
        let url = URL(string: "https://api.example.com/chat/completions")!
        let fetch: FetchFunction = { request in
            let index = await capture.request(request.httpBody ?? Data())
            guard responses.indices.contains(index) else { throw FixtureError.unexpectedRequest }
            let chunks = responses[index]
            return FetchResponse(
                body: .stream(AsyncThrowingStream { continuation in
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                }),
                urlResponse: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"])!
            )
        }
        let provider = createOpenAICompatibleProvider(settings: .init(
            baseURL: "https://api.example.com", name: "hanlin-openai-compatible", fetch: fetch
        ))
        let model = try provider.languageModel(modelId: "test-model")
        let schema: FlexibleSchema<JSONValue> = FlexibleSchema(jsonSchema(.object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])))
        let tools: ToolSet = [
            "search": tool(inputSchema: schema, execute: { input, options in
                #expect(input == .object(["query": .string("source")]))
                #expect(options.toolCallId == "search-call")
                await capture.executed("search")
                return .value(JSONValue.string("original-search-result"))
            }),
            "resolve": tool(inputSchema: schema, execute: { input, options in
                #expect(input == .object(["query": .string("reference")]))
                #expect(options.toolCallId == "reference-call")
                await capture.executed("resolve")
                return .value(JSONValue.string("original-reference-result"))
            })
        ]
        let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(model), prompt: "Search, resolve the source, and answer.",
            tools: tools, stopWhen: [stepCountIs(4)]
        )
        #expect(try await convertReadableStreamToArray(result.textStream) == ["English and עברית answer."])
        #expect(await capture.toolExecutions() == ["search", "resolve"])
        let steps = try await result.steps
        #expect(steps.count == 3)
        #expect(steps.map(\.finishReason) == [.stop, .stop, .stop])
        #expect(steps.prefix(2).map { $0.toolResults.count } == [1, 1])

        let requests = await capture.requests()
        try #require(requests.count == 3)
        let initial = try requestMessages(requests[0])
        let second = try requestMessages(requests[1])
        let third = try requestMessages(requests[2])
        #expect(assistantCalls(initial).isEmpty)
        let firstCall = expectedCall(id: "search-call", name: "search", query: "source",
            signature: firstSignature)
        let secondCall = expectedCall(id: "reference-call", name: "resolve", query: "reference",
            signature: secondSignature)
        #expect(assistantCalls(second) == [firstCall])
        #expect(assistantCalls(third) == [firstCall, secondCall])
        #expect(assistantCalls(second).map(wireSignatureBytes) == [Array(firstSignature.utf8)])
        #expect(assistantCalls(third).map(wireSignatureBytes) == [
            Array(firstSignature.utf8), Array(secondSignature.utf8)
        ])
        #expect(second.filter { $0["role"] == .string("tool") } == [[
            "role": .string("tool"), "tool_call_id": .string("search-call"),
            "content": .string("original-search-result")
        ]])
        #expect(third.filter { $0["role"] == .string("tool") } == [
            ["role": .string("tool"), "tool_call_id": .string("search-call"),
                "content": .string("original-search-result")],
            ["role": .string("tool"), "tool_call_id": .string("reference-call"),
                "content": .string("original-reference-result")]
        ])
    }
}
