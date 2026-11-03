import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ChatViewModel: ObservableObject {
    static let shared = ChatViewModel()

    @Published var conversation: Conversation
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published var draft = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var includeScreen = false
    @Published private(set) var recentFiles: [String] = []

    let settings = AppSettings.shared
    let store = ConversationStore.shared
    let workspace = Workspace.shared
    let speech = SpeechRecognizer()

    /// Platform-specific tools (Photos on iOS, Mac control on macOS).
    var platformTools: [AgentTool] = []
    /// macOS: grabs the screen when "include screen" is on.
    var screenCapturer: (@MainActor () async throws -> Attachment)?
    /// Extra per-turn context, e.g. the frontmost Mac app.
    var contextProvider: (@MainActor () -> String?)?

    private var runTask: Task<Void, Never>?

    private init() {
        conversation = Conversation(systemPrompt: SystemPrompts.make(settings: AppSettings.shared))
        speech.onAutoFinish = { [weak self] text in
            self?.send(text)
        }
        VoiceOutput.shared.onFinish = { [weak self] in
            self?.voiceReplyFinished()
        }
    }

    var allTools: [AgentTool] { Toolbox.sharedTools() + platformTools }

    var orbMode: CoreOrbView.Mode {
        if speech.isRecording { return .listening }
        if isRunning { return .thinking }
        if VoiceOutput.shared.isSpeaking { return .speaking }
        return .idle
    }

    // MARK: Conversations

    func newConversation() {
        stop()
        store.save(conversation)
        conversation = Conversation(systemPrompt: SystemPrompts.make(settings: settings))
        recentFiles = []
        pendingAttachments = []
    }

    func open(_ id: UUID) {
        guard id != conversation.id else { return }
        stop()
        store.save(conversation)
        if let loaded = store.load(id) {
            conversation = loaded
            recentFiles = []
        }
    }

    func delete(_ id: UUID) {
        store.delete(id)
        if id == conversation.id {
            conversation = Conversation(systemPrompt: SystemPrompts.make(settings: settings))
        }
    }

    // MARK: Sending

    func send(_ textOverride: String? = nil) {
        let text = (textOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty || !pendingAttachments.isEmpty else { return }
        if speech.isRecording { speech.stop() }
        draft = ""
        let attachments = pendingAttachments
        pendingAttachments = []
        let wantsScreen = includeScreen
        VoiceOutput.shared.stop()
        Haptics.tap()
        runTask = Task { await self.run(text: text, attachments: attachments, wantsScreen: wantsScreen) }
    }

    /// Re-runs the agent after an error without adding a new user message.
    func retry() {
        guard !isRunning else { return }
        while conversation.messages.last?.isLocalNotice == true { conversation.messages.removeLast() }
        guard conversation.messages.last?.role != .assistant else { return }
        runTask = Task { await self.runAgent() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        VoiceOutput.shared.stop()
        if speech.isRecording { speech.stop() }
    }

    func toggleListening() {
        VoiceOutput.shared.stop()
        speech.autoFinishAfterSilence = settings.handsFree
        speech.toggle(localeID: settings.recognitionLocale)
    }

    /// Sends what was dictated (push-to-talk mode).
    func finishListening() {
        guard speech.isRecording else { return }
        let text = speech.transcript
        speech.stop()
        if !text.isEmpty { send(text) }
    }

    private func run(text: String, attachments: [Attachment], wantsScreen: Bool) async {
        isRunning = true
        var parts: [MessagePart] = [.text(SystemPrompts.turnContext(extra: contextProvider?()), hidden: true)]
        if !text.isEmpty { parts.append(.text(text)) }
        parts.append(contentsOf: attachments.map { .attachment($0) })

        if wantsScreen, let capturer = screenCapturer {
            status = "Looking at your screen…"
            do {
                parts.append(.attachment(try await capturer()))
            } catch {
                append(.notice("I couldn't capture the screen: \(error.localizedDescription)"))
            }
        }

        if conversation.messages.isEmpty || conversation.title == "New conversation" {
            conversation.title = ChatViewModel.title(for: text, attachments: attachments)
        }
        append(ChatMessage(role: .user, parts: parts))
        await runAgent()
    }

    private func runAgent() async {
        isRunning = true
        defer {
            isRunning = false
            status = ""
            runTask = nil
        }
        let startCount = conversation.messages.count
        do {
            let provider = try await AgentEngine.makeProvider(settings: settings)
            let context = ToolContext(workspace: workspace, settings: settings, approvals: ApprovalCenter.shared)
            let engine = AgentEngine(tools: allTools, context: context)
            let session = try await engine.run(
                history: conversation.messages,
                system: conversation.systemPrompt,
                sessionID: conversation.claudeCodeSessionID,
                provider: provider,
                maxSteps: settings.maxAgentSteps,
                onMessage: { [weak self] message in self?.append(message) },
                onStatus: { [weak self] text in self?.status = text }
            )
            conversation.claudeCodeSessionID = session
            Haptics.success()
            let reply = conversation.messages[startCount...]
                .filter { $0.role == .assistant && !$0.isLocalNotice }
                .last?.visibleText ?? ""
            replyFinished(reply)
        } catch is CancellationError {
            append(.notice("Stopped."))
        } catch {
            Haptics.error()
            append(.notice("⚠️ \(error.localizedDescription)"))
        }
        store.save(conversation)
    }

    private func append(_ message: ChatMessage) {
        conversation.messages.append(message)
        conversation.updated = Date()
        for result in message.toolResults where !result.files.isEmpty {
            recentFiles.insert(contentsOf: result.files, at: 0)
        }
        if recentFiles.count > 30 { recentFiles = Array(recentFiles.prefix(30)) }
    }

    private func replyFinished(_ reply: String) {
        guard settings.speakReplies || settings.handsFree, !reply.isEmpty else { return }
        VoiceOutput.shared.speak(reply)
    }

    private func voiceReplyFinished() {
        // Hands-free: keep the conversation going.
        guard settings.handsFree, !isRunning, !speech.isRecording else { return }
        speech.autoFinishAfterSilence = true
        Task { await speech.start(localeID: settings.recognitionLocale) }
    }

    // MARK: Attachments

    func attach(data: Data, name: String, mimeType: String) {
        if mimeType.hasPrefix("image/"), let prepared = ImageCoder.preparedForModel(data) {
            let base = (name as NSString).deletingPathExtension
            pendingAttachments.append(Attachment(name: base + ".jpg", mimeType: prepared.mimeType, data: prepared.data))
        } else {
            pendingAttachments.append(Attachment(name: name, mimeType: mimeType, data: data))
        }
    }

    func attach(fileURL url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        attach(data: data, name: url.lastPathComponent, mimeType: Workspace.mimeType(for: url))
    }

    static func title(for text: String, attachments: [Attachment]) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        if clean.isEmpty { return attachments.first?.isImage == true ? "Image question" : "Attachment" }
        return clean.count > 48 ? String(clean.prefix(46)) + "…" : clean
    }

    struct QuickPrompt: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
        init(_ icon: String, _ text: String) { self.icon = icon; self.text = text }
    }

    static let quickPrompts: [QuickPrompt] = [
        QuickPrompt("doc.text", "Make a packing list for a 3-day trip to Paris"),
        QuickPrompt("photo", "Draw a futuristic neon city wallpaper for my phone"),
        QuickPrompt("doc.richtext", "Write a one-page PDF cover letter for a junior designer job"),
        QuickPrompt("chart.bar", "Make a bar chart of my week: Mon 3h, Tue 5h, Wed 2h, Thu 6h, Fri 4h"),
        QuickPrompt("waveform", "Record a 30-second calming bedtime story as audio"),
        QuickPrompt("qrcode", "Create a QR code for https://apple.com"),
        QuickPrompt("calendar", "Create a calendar event file for dinner Friday at 8pm"),
        QuickPrompt("chevron.left.forwardslash.chevron.right", "Build a small HTML page with a working calculator")
    ]
}
