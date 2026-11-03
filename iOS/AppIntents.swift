import AppIntents
import Foundation

/// "Hey Siri, ask JARVIS" / Shortcuts action. Runs the agent headlessly and
/// returns its answer; any files it creates land in the JARVIS folder.
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask JARVIS"
    static let description: IntentDescription? = IntentDescription("Ask JARVIS to answer something or make a file (notes, PDFs, images, audio…).")
    static let openAppWhenRun = false

    @Parameter(title: "Request", requestValueDialog: "What would you like me to do?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await HeadlessJarvis.run(request)
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
                "Tell \(.applicationName) to make something"
            ],
            shortTitle: "Ask JARVIS",
            systemImageName: "sparkles"
        )
    }
}

@MainActor
enum HeadlessJarvis {
    static func run(_ request: String) async throws -> String {
        let settings = AppSettings.shared
        var conversation = Conversation(systemPrompt: SystemPrompts.make(settings: settings) +
            "\n\nYou are answering through Siri/Shortcuts: keep the final reply to one or two spoken sentences.")
        conversation.title = "Siri: " + ChatViewModel.title(for: request, attachments: [])
        conversation.origin = "siri"
        conversation.messages.append(ChatMessage(role: .user, parts: [
            .text(SystemPrompts.turnContext(), hidden: true),
            .text(request)
        ]))

        let approvals = ApprovalCenter.shared
        approvals.headless = true
        defer { approvals.headless = false }

        let provider = try await AgentEngine.makeProvider(settings: settings)
        let engine = AgentEngine(
            tools: Toolbox.sharedTools() + iOSTools.all,
            context: ToolContext(workspace: Workspace.shared, settings: settings, approvals: approvals)
        )
        var created: [String] = []
        _ = try await engine.run(
            history: conversation.messages,
            system: conversation.systemPrompt,
            sessionID: nil,
            provider: provider,
            maxSteps: settings.maxAgentSteps,
            onMessage: { message in
                conversation.messages.append(message)
                for result in message.toolResults { created.append(contentsOf: result.files) }
            },
            onStatus: { _ in }
        )
        ConversationStore.shared.save(conversation)
        var answer = conversation.messages.last(where: { $0.role == .assistant && !$0.isLocalNotice })?.visibleText ?? "Done."
        if answer.isEmpty { answer = "Done." }
        if !created.isEmpty && !answer.contains(created[0]) {
            answer += " (Saved: \(created.joined(separator: ", ")))"
        }
        return answer
    }
}
