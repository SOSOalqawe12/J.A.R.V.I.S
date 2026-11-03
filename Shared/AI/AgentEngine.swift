import Foundation

/// The agent loop: ask the model, run the tools it calls, feed results back,
/// repeat until it answers without tool calls.
@MainActor
final class AgentEngine {
    private let tools: [AgentTool]
    private let toolsByName: [String: AgentTool]
    private let context: ToolContext

    init(tools: [AgentTool], context: ToolContext) {
        self.tools = tools
        self.context = context
        var map: [String: AgentTool] = [:]
        for tool in tools { map[tool.name] = tool }
        toolsByName = map
    }

    static func makeProvider(settings: AppSettings) async throws -> LLMProvider {
        switch settings.provider {
        case .gemini:
            guard settings.hasGeminiKey else { throw LLMError.missingAPIKey(.gemini) }
            let model = await GeminiModelCatalog.shared.resolve(.chat, preferred: settings.geminiChatModel, apiKey: settings.geminiAPIKey)
            return GeminiProvider(client: GeminiClient(apiKey: settings.geminiAPIKey), model: model)
        case .claude:
            guard settings.hasClaudeKey else { throw LLMError.missingAPIKey(.claude) }
            let model = settings.claudeModel.isEmpty ? ClaudeClient.defaultModel : settings.claudeModel
            return ClaudeProvider(
                client: ClaudeClient(apiKey: settings.claudeAPIKey),
                model: model,
                effort: settings.claudeEffort,
                useRefusalFallback: settings.claudeRefusalFallback
            )
        case .claudeCode:
            #if os(macOS)
            return ClaudeCodeProvider(settings: settings, workspace: Workspace.shared)
            #else
            throw LLMError.unavailable("Claude Code (subscription) is only available in the Mac app.")
            #endif
        }
    }

    /// Runs the loop. New messages are reported through `onMessage` as they
    /// arrive. Returns the (possibly updated) Claude Code session id.
    func run(
        history: [ChatMessage],
        system: String,
        sessionID: String?,
        provider: LLMProvider,
        maxSteps: Int,
        onMessage: (ChatMessage) -> Void,
        onStatus: (String) -> Void
    ) async throws -> String? {
        var history = history
        var session = sessionID
        let specs = provider.kind == .claudeCode ? [] : tools.map(\.spec)

        for step in 0..<max(1, maxSteps) {
            try Task.checkCancellation()
            onStatus(step == 0 ? "Thinking…" : "Reviewing results…")
            let request = LLMRequest(system: system, messages: history, tools: specs, sessionID: session)
            let reply = try await provider.complete(request)
            try Task.checkCancellation()
            if let newSession = reply.sessionID { session = newSession }

            let assistant = ChatMessage(
                role: .assistant,
                parts: reply.parts,
                provider: provider.kind,
                model: reply.model,
                providerRaw: reply.raw
            )
            history.append(assistant)
            onMessage(assistant)
            if let notice = reply.notice { onMessage(.notice(notice)) }

            let calls = assistant.toolCalls
            if calls.isEmpty { return session }

            var results: [MessagePart] = []
            for call in calls {
                if Task.isCancelled {
                    results.append(.result(ToolResult(callID: call.id, name: call.name, output: "Cancelled by the user.", isError: true)))
                    continue
                }
                onStatus("\(toolsByName[call.name]?.activityLabel ?? call.name)…")
                results.append(.result(await execute(call)))
            }
            let toolMessage = ChatMessage(role: .tool, parts: results)
            history.append(toolMessage)
            onMessage(toolMessage)
            try Task.checkCancellation()
        }
        onMessage(.notice("I paused after \(maxSteps) steps. Say \"continue\" and I'll keep going."))
        return session
    }

    private func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = toolsByName[call.name] else {
            return ToolResult(callID: call.id, name: call.name, output: "Unknown tool \"\(call.name)\".", isError: true)
        }
        do {
            let output = try await tool.run(call.arguments, context: context)
            return ToolResult(callID: call.id, name: call.name, output: output.text, images: output.images, files: output.files)
        } catch is CancellationError {
            return ToolResult(callID: call.id, name: call.name, output: "Cancelled by the user.", isError: true)
        } catch {
            return ToolResult(callID: call.id, name: call.name, output: "Error: \(error.localizedDescription)", isError: true)
        }
    }
}
