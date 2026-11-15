/**
 Collect approved and denied tool approvals from conversation messages.

 Port of `@ai-sdk/ai/src/generate-text/collect-tool-approvals.ts`.
 */
import Foundation
import AISDKProvider
import AISDKProviderUtils

/**
 Collect tool approvals from model messages when the last message comes from a tool.

 Port of `@ai-sdk/ai/src/generate-text/collect-tool-approvals.ts`.
 */
public func collectToolApprovals(
    messages: [ModelMessage]
) -> (
    approvedToolApprovals: [CollectedToolApproval],
    deniedToolApprovals: [CollectedToolApproval]
) {
    guard
        let lastMessage = messages.last,
        case .tool(let toolMessage) = lastMessage
    else {
        return (approvedToolApprovals: [], deniedToolApprovals: [])
    }

    var toolCallsById: [String: TypedToolCall] = [:]
    var approvalRequestsById: [String: ToolApprovalRequest] = [:]
    var ambiguousCallIds: Set<String> = []
    var ambiguousApprovalIds: Set<String> = []

    for message in messages {
        guard case .assistant(let assistantMessage) = message else { continue }

        switch assistantMessage.content {
        case .text:
            continue

        case .parts(let parts):
            for part in parts {
                switch part {
                case let .toolCall(toolCallPart):
                    let typedCall: TypedToolCall
                    if toolCallPart.dynamic == true {
                        typedCall = .dynamic(DynamicToolCall(
                            toolCallId: toolCallPart.toolCallId,
                            toolName: toolCallPart.toolName,
                            input: toolCallPart.input,
                            providerExecuted: toolCallPart.providerExecuted,
                            providerMetadata: toolCallPart.providerOptions,
                            rawInput: toolCallPart.rawInput
                        ))
                    } else {
                        typedCall = .static(StaticToolCall(
                            toolCallId: toolCallPart.toolCallId,
                            toolName: toolCallPart.toolName,
                            input: toolCallPart.input,
                            providerExecuted: toolCallPart.providerExecuted,
                            providerMetadata: toolCallPart.providerOptions,
                            rawInput: toolCallPart.rawInput
                        ))
                    }
                    if toolCallsById[toolCallPart.toolCallId] != nil {
                        ambiguousCallIds.insert(toolCallPart.toolCallId)
                    }
                    toolCallsById[toolCallPart.toolCallId] = typedCall

                case let .toolApprovalRequest(approvalRequest):
                    if approvalRequestsById[approvalRequest.approvalId] != nil {
                        ambiguousApprovalIds.insert(approvalRequest.approvalId)
                    }
                    approvalRequestsById[approvalRequest.approvalId] = approvalRequest

                default:
                    break
                }
            }
        }
    }

    var toolResultsByCallId: Set<String> = []
    for part in toolMessage.content {
        if case .toolResult(let resultPart) = part {
            toolResultsByCallId.insert(resultPart.toolCallId)
        }
    }

    var approved: [CollectedToolApproval] = []
    var denied: [CollectedToolApproval] = []

    var responseCounts: [String: Int] = [:]
    for part in toolMessage.content {
        if case .toolApprovalResponse(let response) = part {
            responseCounts[response.approvalId, default: 0] += 1
        }
    }
    for part in toolMessage.content {
        guard case .toolApprovalResponse(let response) = part else { continue }
        guard let approvalRequest = approvalRequestsById[response.approvalId] else {
            continue
        }

        if ambiguousApprovalIds.contains(response.approvalId)
            || ambiguousCallIds.contains(approvalRequest.toolCallId)
            || responseCounts[response.approvalId] != 1
            || toolResultsByCallId.contains(approvalRequest.toolCallId) {
            continue
        }

        guard let toolCall = toolCallsById[approvalRequest.toolCallId] else {
            continue
        }

        let collected = CollectedToolApproval(
            approvalRequest: approvalRequest,
            approvalResponse: response,
            toolCall: toolCall
        )

        if response.approved {
            approved.append(collected)
        } else {
            denied.append(collected)
        }
    }

    return (approvedToolApprovals: approved, deniedToolApprovals: denied)
}

/// Collected tool approval (request, response, and associated tool call).
public struct CollectedToolApproval: Sendable {
    public let approvalRequest: ToolApprovalRequest
    public let approvalResponse: ToolApprovalResponse
    public let toolCall: TypedToolCall

    public init(
        approvalRequest: ToolApprovalRequest,
        approvalResponse: ToolApprovalResponse,
        toolCall: TypedToolCall
    ) {
        self.approvalRequest = approvalRequest
        self.approvalResponse = approvalResponse
        self.toolCall = toolCall
    }
}
