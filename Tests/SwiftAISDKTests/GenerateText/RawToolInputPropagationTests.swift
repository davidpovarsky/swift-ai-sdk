import Foundation
import Testing
import AISDKProvider
import AISDKProviderUtils
@testable import SwiftAISDK

@Suite("Raw tool input propagation")
struct RawToolInputPropagationTests {
    private let schema = FlexibleSchema(jsonSchema(.object(["type": .string("object")])))
    private let samples = [
        "{\"n\":9007199254740991}", "{\"n\":9007199254740992}",
        "{\"n\":9007199254740993}", "{\"n\":9223372036854775807}",
        "{\"n\":-9223372036854775808}", "{\"n\":1.0}", "{\"n\":1e0}",
        "{\"a\":[{\"n\":9007199254740993},1.0,1e0],\"s\":\"123\"}"
    ]

    private actor Recorder {
        var values: [ToolCallRawInput?] = []
        func append(_ value: ToolCallRawInput?) { values.append(value) }
    }

    private actor ValidationGate {
        var armed = false
        var held: CheckedContinuation<Void, Never>?
        var observer: CheckedContinuation<Void, Never>?
        func arm() { armed = true }
        func holdIfArmed() async {
            guard armed else { return }
            await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
        }
        func waitUntilHeld() async {
            if held != nil { return }
            await withCheckedContinuation { observer = $0 }
        }
        func release() { armed = false; held?.resume(); held = nil }
    }

    private func tools(_ recorder: Recorder, dynamic: Bool = false, approval: Bool = false) -> ToolSet {
        ["echo": Tool(
            inputSchema: schema,
            needsApproval: approval ? .always : nil,
            execute: { _, options in
                await recorder.append(options.rawInput)
                return .value(.string("ok"))
            },
            type: dynamic ? .dynamic : .function
        )]
    }

    private func parse(_ json: String, tools: ToolSet, repair: ToolCallRepairFunction? = nil) async -> TypedToolCall {
        await parseToolCall(
            toolCall: LanguageModelV3ToolCall(toolCallId: "c1", toolName: "echo", input: json),
            tools: tools, repairToolCall: repair, system: nil, messages: []
        )
    }

    private func execute(_ call: TypedToolCall, tools: ToolSet, abort: (@Sendable () -> Bool)? = nil) async -> ToolOutput? {
        await executeToolCall(toolCall: call, tools: tools, tracer: MockTracer(), telemetry: nil,
                              messages: [], abortSignal: abort, experimentalContext: nil)
    }

    private func approvalMessages(_ call: TypedToolCall, approved: Bool = true) throws -> [ModelMessage] {
        let content: [ContentPart] = [
            .toolCall(call, providerMetadata: nil),
            .toolApprovalRequest(ToolApprovalRequestOutput(approvalId: "a1", toolCall: call))
        ]
        var messages = toResponseMessages(content: content, tools: nil)
        messages.append(.tool(ToolModelMessage(content: [
            .toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: approved))
        ])))
        return try JSONDecoder().decode([ModelMessage].self, from: JSONEncoder().encode(messages))
    }

    private func finishModel() -> MockLanguageModelV3 {
        MockLanguageModelV3(doGenerate: .singleValue(LanguageModelV3GenerateResult(
            content: [.text(LanguageModelV3Text(text: "done"))],
            finishReason: .init(unified: .stop),
            usage: LanguageModelV3Usage(inputTokens: .init(total: 1), outputTokens: .init(total: 1))
        )))
    }

    @Test("real parse and execute preserve final JSON for static and dynamic tools")
    func immediate() async throws {
        for dynamic in [false, true] {
            for json in samples {
                let recorder = Recorder()
                let tools = tools(recorder, dynamic: dynamic)
                let call = await parse(json, tools: tools)
                #expect(call.invalid != true)
                #expect(call.isDynamic == dynamic)
                #expect(call.rawInput?.json == json)
                let output = await execute(call, tools: tools)
                guard case .result = output else { Issue.record("Expected execution result"); continue }
                #expect(await recorder.values == [ToolCallRawInput(toolCallId: "c1", toolName: "echo", json: json)])
            }
        }
    }

    @Test("accepted repair bytes replace failed bytes and survive actual approval resume")
    func repairedApprovalResume() async throws {
        for dynamic in [false, true] {
            for json in samples {
                let recorder = Recorder()
                let tools = tools(recorder, dynamic: dynamic, approval: true)
                let call = await parse("invalid", tools: tools, repair: { options in
                    LanguageModelV3ToolCall(toolCallId: options.toolCall.toolCallId, toolName: "echo", input: json)
                })
                #expect(call.rawInput?.json == json)
                let messages = try approvalMessages(call)
                let collected = collectToolApprovals(messages: messages)
                #expect(collected.approvedToolApprovals.first?.toolCall.isDynamic == dynamic)
                let _: DefaultGenerateTextResult<JSONValue> = try await generateText(
                    model: .v3(finishModel()), tools: tools, messages: messages
                )
                #expect(await recorder.values == [ToolCallRawInput(toolCallId: "c1", toolName: "echo", json: json)])
            }
        }
    }

    @Test("stream immediate and resolver approval pass original final bytes")
    func streamedExecution() async throws {
        for dynamic in [false, true] {
            for approval in [false, true] {
                let json = samples.last!
                let recorder = Recorder()
                let tools = tools(recorder, dynamic: dynamic, approval: approval)
                let parts: [LanguageModelV3StreamPart] = [
                    .streamStart(warnings: []),
                    .toolCall(LanguageModelV3ToolCall(toolCallId: "c1", toolName: "echo", input: json)),
                    .finish(finishReason: .init(unified: .toolCalls),
                            usage: LanguageModelV3Usage(inputTokens: .init(total: 1), outputTokens: .init(total: 1)),
                            providerMetadata: nil)
                ]
                let stream = AsyncThrowingStream<LanguageModelV3StreamPart, Error> { continuation in
                    parts.forEach { continuation.yield($0) }; continuation.finish()
                }
                let model = MockLanguageModelV3(doStream: .singleValue(LanguageModelV3StreamResult(stream: stream)))
                let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
                    model: .v3(model), prompt: "test", tools: tools,
                    experimentalApprove: { _ in .approve }
                )
                _ = try await result.collectFullStream()
                #expect(await recorder.values == [ToolCallRawInput(toolCallId: "c1", toolName: "echo", json: json)])
            }
        }
    }

    @Test("invalid, oversized, schema denied, and changed repair ID never execute")
    func rejectedParse() async throws {
        let recorder = Recorder()
        let tools = tools(recorder)
        for json in ["{", "[]", String(repeating: " ", count: ToolCallRawInput.maximumUTF8Bytes + 1)] {
            let call = await parse(json, tools: tools)
            #expect(call.invalid == true)
            #expect(call.rawInput == nil)
            _ = await execute(call, tools: tools)
        }
        let call = await parse("invalid", tools: tools, repair: { _ in
            LanguageModelV3ToolCall(toolCallId: "different-call", toolName: "echo", input: "{}")
        })
        #expect(call.invalid == true)
        _ = await execute(call, tools: tools)
        #expect(await recorder.values.isEmpty)
    }

    @Test("persisted raw input must match call, tool, value, dynamic type and current schema")
    func forgedOrStaleProvenance() async throws {
        let recorder = Recorder()
        let tools = tools(recorder)
        let valid = await parse("{\"n\":1}", tools: tools)
        for raw in [
            ToolCallRawInput(toolCallId: "other", toolName: "echo", json: "{\"n\":1}"),
            ToolCallRawInput(toolCallId: "c1", toolName: "other", json: "{\"n\":1}"),
            ToolCallRawInput(toolCallId: "c1", toolName: "echo", json: "{"),
            ToolCallRawInput(toolCallId: "c1", toolName: "echo", json: "{\"n\":2}"),
            ToolCallRawInput(toolCallId: "c1", toolName: "echo", json: String(repeating: " ", count: ToolCallRawInput.maximumUTF8Bytes + 1))
        ] {
            let call = TypedToolCall.static(StaticToolCall(toolCallId: "c1", toolName: "echo", input: valid.input, rawInput: raw))
            _ = await execute(call, tools: tools)
            let _: DefaultGenerateTextResult<JSONValue> = try await generateText(
                model: .v3(finishModel()), tools: tools, messages: approvalMessages(call)
            )
        }
        _ = await execute(valid, tools: self.tools(recorder, dynamic: true))
        let staleTools: ToolSet = ["echo": Tool(
            inputSchema: FlexibleSchema(jsonSchema(.object(["type": .string("object"), "required": .array([.string("missing")])]))),
            execute: { _, options in await recorder.append(options.rawInput); return .value(.null) }
        )]
        _ = await execute(valid, tools: staleTools)
        let _: DefaultGenerateTextResult<JSONValue> = try await generateText(
            model: .v3(finishModel()), tools: staleTools, messages: approvalMessages(valid)
        )
        _ = await execute(valid, tools: tools, abort: { true })
        #expect(await recorder.values.isEmpty)
    }

    @Test("cancellation during live schema validation prevents executor entry")
    func cancellationDuringValidation() async throws {
        let recorder = Recorder()
        let gate = ValidationGate()
        let schema = Schema<JSONValue>(jsonSchemaResolver: { .object([:]) }, validator: { value in
            let converted = try jsonValue(from: value)
            await gate.holdIfArmed()
            return .success(value: converted)
        })
        let tools: ToolSet = ["echo": Tool(inputSchema: FlexibleSchema(schema), execute: { _, options in
            await recorder.append(options.rawInput); return .value(.null)
        })]
        let call = await parse(samples[0], tools: tools)
        await gate.arm()
        let task = Task { await execute(call, tools: tools) }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.release()
        _ = await task.value
        #expect(await recorder.values.isEmpty)
    }

    @Test("denial, unknown approval and ambiguous correlation do not resume execution")
    func deniedOrAmbiguousResume() async throws {
        let recorder = Recorder()
        let tools = tools(recorder, approval: true)
        let call = await parse(samples[0], tools: tools)
        let denied = try approvalMessages(call, approved: false)
        let _: DefaultGenerateTextResult<JSONValue> = try await generateText(model: .v3(finishModel()), tools: tools, messages: denied)
        var ambiguous = try approvalMessages(call)
        ambiguous.append(.tool(ToolModelMessage(content: [
            .toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: true)),
            .toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: true))
        ])))
        #expect(collectToolApprovals(messages: ambiguous).approvedToolApprovals.isEmpty)
        let _: DefaultGenerateTextResult<JSONValue> = try await generateText(model: .v3(finishModel()), tools: tools, messages: ambiguous)
        var unknown = try approvalMessages(call)
        unknown[unknown.count - 1] = .tool(ToolModelMessage(content: [
            .toolApprovalResponse(ToolApprovalResponse(approvalId: "unknown", approved: true))
        ]))
        let _: DefaultGenerateTextResult<JSONValue> = try await generateText(model: .v3(finishModel()), tools: tools, messages: unknown)
        #expect(await recorder.values.isEmpty)
    }

    @Test("legacy missing provenance remains nil; no normalized JSON is called raw")
    func legacy() async throws {
        let recorder = Recorder()
        let tools = tools(recorder)
        let call = TypedToolCall.static(StaticToolCall(toolCallId: "c1", toolName: "echo", input: .object([:])))
        let collected = collectToolApprovals(messages: try approvalMessages(call))
        #expect(collected.approvedToolApprovals.first?.toolCall.rawInput == nil)
        _ = await execute(call, tools: tools)
        #expect(await recorder.values.count == 1)
        #expect(await recorder.values.first! == nil)
        let empty = await parse("", tools: tools)
        #expect(empty.invalid != true && empty.rawInput == nil)
    }
}
