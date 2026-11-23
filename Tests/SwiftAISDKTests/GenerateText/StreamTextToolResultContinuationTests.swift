import Foundation
import Testing
import AISDKProvider
import AISDKProviderUtils
@testable import SwiftAISDK

@Suite("StreamText tool-result continuation")
struct StreamTextToolResultContinuationTests {
    private actor Calls {
        var names: [String] = []
        func record(_ name: String) { names.append(name) }
        func values() -> [String] { names }
    }

    private let usage = LanguageModelV3Usage(
        inputTokens: .init(total: 2), outputTokens: .init(total: 2)
    )

    private var schema: FlexibleSchema<JSONValue> {
        FlexibleSchema(jsonSchema(.object([
            "type": .string("object"),
            "additionalProperties": .bool(true)
        ])))
    }

    private func toolStep(
        id: String,
        name: String,
        reason: LanguageModelV3FinishReason.Unified = .stop
    ) -> LanguageModelV3StreamResult {
        stream([
            .streamStart(warnings: []),
            .toolCall(LanguageModelV3ToolCall(
                toolCallId: id, toolName: name, input: "{}",
                providerExecuted: false, providerMetadata: nil
            )),
            .finish(
                finishReason: LanguageModelV3FinishReason(
                    unified: reason, raw: reason == .toolCalls ? "tool_calls" : "stop"
                ),
                usage: usage, providerMetadata: nil
            )
        ])
    }

    private func answerStep(_ text: String) -> LanguageModelV3StreamResult {
        stream([
            .streamStart(warnings: []),
            .textStart(id: "answer", providerMetadata: nil),
            .textDelta(id: "answer", delta: text, providerMetadata: nil),
            .textEnd(id: "answer", providerMetadata: nil),
            .finish(
                finishReason: LanguageModelV3FinishReason(unified: .stop, raw: "stop"),
                usage: usage, providerMetadata: nil
            )
        ])
    }

    private func stream(_ parts: [LanguageModelV3StreamPart]) -> LanguageModelV3StreamResult {
        LanguageModelV3StreamResult(stream: AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            continuation.finish()
        })
    }

    private func toolResultIDs(_ prompt: LanguageModelV3Prompt) -> [String] {
        prompt.flatMap { message -> [String] in
            guard case .tool(let content, _) = message else { return [] }
            return content.compactMap { part in
                guard case .toolResult(let result) = part else { return nil }
                return result.toolCallId
            }
        }
    }

    @Test(
        "Completed client tools reach subsequent model steps with original result identities",
        arguments: [LanguageModelV3FinishReason.Unified.stop, .toolCalls]
    )
    func twoToolConversation(reason: LanguageModelV3FinishReason.Unified) async throws {
        let calls = Calls()
        let model = MockLanguageModelV3(doStream: .array([
            toolStep(id: "search-call", name: "search", reason: reason),
            toolStep(id: "reference-call", name: "resolve", reason: reason),
            answerStep("English and עברית with the resolved source")
        ]))
        let tools: ToolSet = [
            "search": tool(inputSchema: schema, execute: { _, _ in
                await calls.record("search")
                return .value(JSONValue.string("original-search-result"))
            }),
            "resolve": tool(inputSchema: schema, execute: { _, _ in
                await calls.record("resolve")
                return .value(JSONValue.string("original-reference-result"))
            })
        ]
        let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(model), prompt: "Search, resolve the source, and answer.",
            tools: tools, stopWhen: [stepCountIs(4)]
        )

        let text = try await convertReadableStreamToArray(result.textStream)
        #expect(text == ["English and עברית with the resolved source"])
        #expect(await calls.values() == ["search", "resolve"])
        let steps = try await result.steps
        #expect(steps.count == 3)
        #expect(steps.first?.finishReason == reason)
        #expect(steps.last?.finishReason == .stop)
        let requests = model.doStreamCalls
        try #require(requests.count == 3)
        #expect(toolResultIDs(requests[1].prompt) == ["search-call"])
        #expect(toolResultIDs(requests[2].prompt) == ["search-call", "reference-call"])
        let finalPrompt = String(decoding: try JSONEncoder().encode(requests[2].prompt), as: UTF8.self)
        #expect(finalPrompt.contains("original-search-result"))
        #expect(finalPrompt.contains("original-reference-result"))
    }

    @Test("An explicit one-step budget still stops after a completed client tool")
    func budgetStopsContinuation() async throws {
        let model = MockLanguageModelV3(doStream: .array([
            toolStep(id: "bounded-call", name: "search"),
            answerStep("must not be requested")
        ]))
        let tools: ToolSet = [
            "search": tool(inputSchema: schema, execute: { _, _ in
                .value(JSONValue.string("completed"))
            })
        ]
        let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(model), prompt: "Search once.", tools: tools,
            stopWhen: [stepCountIs(1)]
        )
        _ = try await convertReadableStreamToArray(result.fullStream)
        #expect(try await result.steps.count == 1)
        #expect(model.doStreamCalls.count == 1)
    }

    @Test("An unresolved client tool does not authorize another model step")
    func missingToolOutputStopsContinuation() async throws {
        let model = MockLanguageModelV3(doStream: .array([
            toolStep(id: "pending-call", name: "search"),
            answerStep("must not be requested")
        ]))
        let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(model), prompt: "Search.",
            tools: ["search": tool(inputSchema: schema)],
            stopWhen: [stepCountIs(4)]
        )
        _ = try await convertReadableStreamToArray(result.fullStream)
        let steps = try await result.steps
        #expect(steps.count == 1)
        #expect(steps.first?.toolResults.isEmpty == true)
        #expect(model.doStreamCalls.count == 1)
    }

    @Test("Text completion neither requests another step nor evaluates tool-loop stop conditions")
    func textCompletionStopsNormally() async throws {
        let calls = Calls()
        let model = MockLanguageModelV3(doStream: .array([
            answerStep("complete"), answerStep("must not be requested")
        ]))
        let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(model), prompt: "Answer.",
            stopWhen: [{ _ in
                await calls.record("stop-condition")
                return false
            }]
        )
        #expect(try await convertReadableStreamToArray(result.textStream) == ["complete"])
        #expect(model.doStreamCalls.count == 1)
        #expect(await calls.values().isEmpty)
    }

    @Test("A completed tool error is returned to the model even when the provider reports stop")
    func toolErrorContinuesWithoutReexecution() async throws {
        enum ExpectedError: Error { case lookupFailed }
        let calls = Calls()
        let model = MockLanguageModelV3(doStream: .array([
            toolStep(id: "failed-call", name: "search"),
            answerStep("The lookup failed.")
        ]))
        let tools: ToolSet = [
            "search": tool(inputSchema: schema, execute: { _, _ -> ToolExecutionResult<JSONValue> in
                await calls.record("search")
                throw ExpectedError.lookupFailed
            })
        ]
        let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(model), prompt: "Search.", tools: tools,
            stopWhen: [stepCountIs(3)]
        )
        #expect(try await convertReadableStreamToArray(result.textStream) == ["The lookup failed."])
        #expect(await calls.values() == ["search"])
        let steps = try await result.steps
        #expect(steps.count == 2)
        #expect(steps.first?.toolErrors.count == 1)
        let requests = model.doStreamCalls
        try #require(requests.count == 2)
        #expect(toolResultIDs(requests[1].prompt) == ["failed-call"])
    }
}
