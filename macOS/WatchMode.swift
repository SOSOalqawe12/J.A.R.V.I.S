import Foundation
import AppKit
import SwiftUI
import CoreGraphics

struct Suggestion: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var detail: String
    var actionType: String
    var actionValue: String
    var appName: String?
    var date = Date()

    var actionLabel: String? {
        switch actionType {
        case "open_url": return "Open link"
        case "open_app": return "Open app"
        case "copy_text": return "Copy"
        case "run_shell": return "Run command"
        case "applescript": return "Run script"
        case "ask": return "Ask JARVIS"
        default: return nil
        }
    }

    var actionIcon: String {
        switch actionType {
        case "open_url": return "safari"
        case "open_app": return "app.badge"
        case "copy_text": return "doc.on.doc"
        case "run_shell": return "terminal"
        case "applescript": return "applescript"
        case "ask": return "sparkles"
        default: return "lightbulb"
        }
    }
}

/// "Screen watch": periodically looks at the screen and proposes next steps.
@MainActor
final class WatchModeController: ObservableObject {
    static let shared = WatchModeController()

    @Published private(set) var isWatching = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var lastSummary = ""
    @Published private(set) var lastRun: Date?
    @Published var statusMessage = ""

    private var loop: Task<Void, Never>?
    private var lastFingerprint: [UInt8]?

    static let systemPrompt = """
    You are JARVIS, a proactive desktop assistant looking at a screenshot of the user's Mac. \
    Work out what the user is doing and propose 1–3 genuinely useful, specific next steps: \
    shortcuts, fixes for visible errors, better approaches, things they may have forgotten, \
    relevant resources, or tasks JARVIS could do for them. Avoid generic advice. \
    Never repeat sensitive data you see (passwords, keys, card numbers). \
    If nothing useful comes to mind, return an empty list.
    Reply with ONLY a JSON object:
    {"summary": "<one sentence: what the user is doing>",
     "suggestions": [{"title": "<short imperative>", "detail": "<1-2 sentences>",
       "action": {"type": "open_url|open_app|copy_text|run_shell|applescript|ask|none", "value": "<url, app name, text, command, script, or a request for JARVIS>"}}]}
    """

    func toggle() { isWatching ? stop() : start() }

    func start() {
        guard !isWatching else { return }
        if !ScreenCapture.hasPermission {
            ScreenCapture.requestPermission()
            statusMessage = "Grant Screen Recording permission, then turn watch on again."
            return
        }
        isWatching = true
        statusMessage = "Watching…"
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.analyze(force: false)
                let interval = max(20, AppSettings.shared.watchInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isWatching = false
        statusMessage = "Watch paused."
    }

    func clear() { suggestions.removeAll() }

    private var userIdleSeconds: Double {
        let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    func analyze(force: Bool) async {
        guard !isAnalyzing else { return }
        let settings = AppSettings.shared
        guard settings.isProviderConfigured else {
            statusMessage = "Add an API key in Settings to use screen watch."
            return
        }
        if !force && userIdleSeconds > 300 {
            statusMessage = "You're away – skipping."
            return
        }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let image = try await ScreenCapture.capture()
            let fingerprint = ImageCoder.fingerprint(image)
            if !force, let last = lastFingerprint, ImageCoder.difference(fingerprint, last) < 2.5 {
                statusMessage = "Screen hasn't changed – nothing new."
                return
            }
            lastFingerprint = fingerprint
            guard let attachment = ImageCoder.preparedForModel(image) else { return }
            let front = ScreenCapture.frontmost()

            var prompt = "Here is my screen right now. \(SystemPrompts.turnContext(extra: ScreenCapture.contextLine()))"
            let focus = settings.watchFocus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !focus.isEmpty { prompt += "\nMy current goal: \(focus)" }
            let recent = suggestions.prefix(6).map(\.title)
            if !recent.isEmpty { prompt += "\nDon't repeat these recent suggestions: " + recent.joined(separator: "; ") }

            statusMessage = "Thinking about your screen…"
            let provider = try await AgentEngine.makeProvider(settings: settings)
            let reply = try await provider.complete(LLMRequest(
                system: WatchModeController.systemPrompt,
                messages: [ChatMessage(role: .user, parts: [.text(prompt), .attachment(attachment)])],
                tools: []
            ))
            let text = reply.parts.compactMap(\.text).joined()
            guard let json = JSONValue.extractObject(from: text) else {
                statusMessage = "Couldn't read the suggestions."
                return
            }
            lastSummary = json["summary"]?.stringValue ?? ""
            let fresh: [Suggestion] = (json["suggestions"]?.arrayValue ?? []).compactMap { item in
                guard let title = item["title"]?.stringValue, !title.isEmpty else { return nil }
                return Suggestion(
                    title: title,
                    detail: item["detail"]?.stringValue ?? "",
                    actionType: item["action"]?["type"]?.stringValue ?? "none",
                    actionValue: item["action"]?["value"]?.stringValue ?? "",
                    appName: front?.appName
                )
            }
            lastRun = Date()
            statusMessage = fresh.isEmpty ? "All good – no suggestions right now." : "\(fresh.count) new suggestion(s)."
            guard !fresh.isEmpty else { return }
            suggestions.insert(contentsOf: fresh, at: 0)
            if suggestions.count > 60 { suggestions = Array(suggestions.prefix(60)) }

            if settings.watchNotifications && !NSApp.isActive, let top = fresh.first {
                await MacNotifier.post(title: "JARVIS: \(top.title)", body: top.detail)
            }
            if settings.watchSpeakSuggestions, let top = fresh.first {
                VoiceOutput.shared.speak(top.title)
            }
        } catch {
            statusMessage = error.localizedDescription
            if (error as? ScreenCaptureError) == .permissionDenied { stop() }
        }
    }

    func perform(_ suggestion: Suggestion) {
        let value = suggestion.actionValue
        switch suggestion.actionType {
        case "open_url":
            if let url = URL(string: value) { NSWorkspace.shared.open(url) }
        case "open_app":
            Task { _ = try? await ProcessRunner.run("/usr/bin/open", arguments: ["-a", value], timeout: 30) }
        case "copy_text":
            Clipboard.copy(value)
            statusMessage = "Copied to clipboard."
        case "run_shell":
            Task {
                guard await ApprovalCenter.shared.requestApproval(title: "Run this command?", detail: "$ \(value)") else { return }
                let result = try? await ProcessRunner.shell(value, currentDirectory: Workspace.shared.root)
                statusMessage = result.map { "Exit \($0.status): \($0.combined.prefix(200))" } ?? "Command failed."
            }
        case "applescript":
            Task {
                guard await ApprovalCenter.shared.requestApproval(title: "Run this AppleScript?", detail: value) else { return }
                let result = try? await ProcessRunner.run("/usr/bin/osascript", arguments: ["-"], input: value)
                statusMessage = result.map { $0.status == 0 ? "Done." : "AppleScript error: \($0.stderr.prefix(200))" } ?? "Failed."
            }
        case "ask":
            askJarvis(about: suggestion)
        default:
            askJarvis(about: suggestion)
        }
    }

    func askJarvis(about suggestion: Suggestion) {
        let chat = ChatViewModel.shared
        chat.includeScreen = true
        let request = suggestion.actionType == "ask" && !suggestion.actionValue.isEmpty
            ? suggestion.actionValue
            : "Help me with this: \(suggestion.title). \(suggestion.detail)"
        MacAppState.shared.showMainWindow(section: .chat)
        chat.send(request)
    }
}

struct SuggestionsView: View {
    @ObservedObject private var watch = WatchModeController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.accent.opacity(0.2))
            if watch.suggestions.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    CoreOrbView(mode: watch.isAnalyzing ? .thinking : .idle, size: 110)
                    Text(watch.isWatching ? "Watching your screen for ways to help…" : "Turn on Screen Watch or press “Analyze now”.")
                        .foregroundColor(Theme.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(watch.suggestions) { suggestion in
                            SuggestionCard(suggestion: suggestion)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Theme.backgroundGradient)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                CoreOrbView(mode: watch.isAnalyzing ? .thinking : .idle, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Screen Watch").font(.title2.weight(.semibold)).foregroundColor(Theme.text)
                    Text(watch.statusMessage.isEmpty ? "JARVIS looks at your screen and suggests what to do next." : watch.statusMessage)
                        .font(.callout).foregroundColor(Theme.secondaryText).lineLimit(2)
                }
                Spacer()
                Toggle("Watch", isOn: Binding(get: { watch.isWatching }, set: { $0 ? watch.start() : watch.stop() }))
                    .toggleStyle(.switch)
                Button {
                    Task { await watch.analyze(force: true) }
                } label: {
                    Label("Analyze now", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(watch.isAnalyzing)
                .keyboardShortcut("r", modifiers: [.command])
            }
            HStack {
                Image(systemName: "scope").foregroundColor(Theme.accent)
                TextField("Optional goal, e.g. “finish the quarterly report” or “learn SwiftUI”", text: $settings.watchFocus)
                    .textFieldStyle(.roundedBorder)
                Picker("Every", selection: $settings.watchInterval) {
                    Text("30 s").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("90 s").tag(90.0)
                    Text("3 min").tag(180.0)
                    Text("5 min").tag(300.0)
                    Text("10 min").tag(600.0)
                }
                .frame(width: 140)
                if !watch.suggestions.isEmpty {
                    Button("Clear") { watch.clear() }
                }
            }
            if !watch.lastSummary.isEmpty {
                Text("Last seen: \(watch.lastSummary)")
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
            }
            if !ScreenCapture.hasPermission {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warm)
                    Text("Screen Recording permission is needed.").foregroundColor(Theme.warm)
                    Button("Open Settings") { ScreenCapture.openPrivacySettings() }
                }
                .font(.callout)
            }
        }
        .padding(16)
    }
}

struct SuggestionCard: View {
    let suggestion: Suggestion
    @ObservedObject private var watch = WatchModeController.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: suggestion.actionIcon)
                .font(.title2)
                .foregroundColor(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.title).font(.headline).foregroundColor(Theme.text)
                if !suggestion.detail.isEmpty {
                    Text(suggestion.detail).font(.callout).foregroundColor(Theme.secondaryText).textSelection(.enabled)
                }
                if !suggestion.actionValue.isEmpty && suggestion.actionType != "ask" && suggestion.actionType != "none" {
                    Text(suggestion.actionValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.accent.opacity(0.85))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if let label = suggestion.actionLabel {
                        Button(label) { watch.perform(suggestion) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                    if suggestion.actionType != "ask" {
                        Button("Ask JARVIS") { watch.askJarvis(about: suggestion) }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Text("\(suggestion.appName ?? "") · \(suggestion.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(Theme.secondaryText)
                }
            }
        }
        .padding(14)
        .hudPanel(cornerRadius: 14)
    }
}
