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
        try await makeProvider(kind: settings.provider, settings: settings)
    }

    /// The backup brain to use when `current` is rate-limited (if configured).
    static func fallbackProvider(for current: ProviderKind, settings: AppSettings) async -> LLMProvider? {
        guard let kind = ProviderKind(rawValue: settings.fallbackProvider), kind != current, settings.isConfigured(kind) else { return nil }
        return try? await makeProvider(kind: kind, settings: settings)
    }

    static func makeProvider(kind: ProviderKind, settings: AppSettings) async throws -> LLMProvider {
        switch kind {
        case .gemini:
            guard settings.hasGeminiKey else { throw LLMError.missingAPIKey(.gemini) }
            let model = await GeminiModelCatalog.shared.resolve(.chat, preferred: settings.geminiChatModel, apiKey: settings.geminiAPIKey)
            // Lite models have much higher free-tier limits: used automatically when the main one is rate-limited.
            let models = await GeminiModelCatalog.shared.models(apiKey: settings.geminiAPIKey)
            let lite = GeminiModelPicker.candidates(models, for: .chat)
                .filter { $0.id.contains("lite") }
                .max { GeminiModelPicker.score($0.id, role: .chat) < GeminiModelPicker.score($1.id, role: .chat) }?.id
            return GeminiProvider(client: GeminiClient(apiKey: settings.geminiAPIKey), model: model, fallbackModel: lite == model ? nil : lite)
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
        case .openai:
            guard settings.hasOpenAIKey else { throw LLMError.missingAPIKey(.openai) }
            let client = OpenAICompatibleClient(baseURL: OpenAICompatibleClient.openAIBaseURL, apiKey: settings.openAIAPIKey)
            var model = settings.openAIModel
            if model.isEmpty { model = await OpenAIModelCatalog.shared.bestModel(client: client) }
            return OpenAICompatibleProvider(kind: .openai, client: client, model: model, toolMode: .native)
        case .local:
            let base = settings.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { throw LLMError.unavailable("Set your local server address in Settings › Local models.") }
            let client = OpenAICompatibleClient(baseURL: base, apiKey: settings.localAPIKey)
            var model = settings.localModel
            if model.isEmpty {
                guard let first = try? await client.listModels().first else {
                    throw LLMError.unavailable("Couldn't reach \(base). Is the server running? From iPhone use your computer's network address, not localhost.")
                }
                model = first
            }
            let mode = OpenAICompatibleProvider.ToolMode(rawValue: settings.localToolMode) ?? .native
            return OpenAICompatibleProvider(kind: .local, client: client, model: model, toolMode: mode)
        case .apple:
            return AppleIntelligenceProvider()
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
        stream: Bool = false,
        onPartial: @escaping @MainActor (String) -> Void = { _ in },
        onMessage: (ChatMessage) -> Void,
        onStatus: (String) -> Void
    ) async throws -> String? {
        var history = history
        var session = sessionID
        var provider = provider
        var switchedProvider = false

        for step in 0..<max(1, maxSteps) {
            try Task.checkCancellation()
            onStatus(step == 0 ? "Thinking…" : "Reviewing results…")
            let specs = provider.kind == .claudeCode ? [] : tools.map(\.spec)
            let request = LLMRequest(system: system, messages: history, tools: specs, sessionID: session)
            let reply: LLMReply
            do {
                reply = try await AgentEngine.call(provider, request, stream: stream, onPartial: onPartial)
            } catch let error as LLMError where error.isRateLimit && !switchedProvider {
                // Main brain is rate-limited: hand over to the backup brain.
                guard let backup = await AgentEngine.fallbackProvider(for: provider.kind, settings: context.settings) else { throw error }
                onMessage(.notice("\(provider.kind.shortName) is rate-limited – \(backup.kind.shortName) is taking over."))
                onStatus("Switching to \(backup.kind.shortName)…")
                provider = backup
                switchedProvider = true
                let backupSpecs = provider.kind == .claudeCode ? [] : tools.map(\.spec)
                reply = try await AgentEngine.call(provider, LLMRequest(system: system, messages: history, tools: backupSpecs, sessionID: nil),
                                                   stream: stream, onPartial: onPartial)
            }
            UsageTracker.shared.record(provider.kind, tokens: reply.tokens)
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

    private static func call(_ provider: LLMProvider, _ request: LLMRequest, stream: Bool,
                             onPartial: @escaping @MainActor (String) -> Void) async throws -> LLMReply {
        if stream {
            return try await provider.completeStreaming(request) { @Sendable text in
                Task { @MainActor in onPartial(text) }
            }
        }
        return try await provider.complete(request)
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

/// Remembers the best OpenAI chat model available to a key.
actor OpenAIModelCatalog {
    static let shared = OpenAIModelCatalog()
    static let fallback = "gpt-4o"
    private var cache: [String: String] = [:]

    func bestModel(client: OpenAICompatibleClient) async -> String {
        if let cached = cache[client.apiKey] { return cached }
        let models = (try? await client.listModels()) ?? []
        let best = OpenAICompatibleClient.bestOpenAIModel(models) ?? OpenAIModelCatalog.fallback
        if !models.isEmpty { cache[client.apiKey] = best }
        return best
    }
}
