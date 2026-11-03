import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine
import UserNotifications

@main
struct JarvisMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("JARVIS", id: "main") {
            MacRootView()
                .frame(minWidth: 860, minHeight: 580)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    ChatViewModel.shared.newConversation()
                    MacAppState.shared.showMainWindow(section: .chat)
                }
                .keyboardShortcut("n")
            }
            CommandMenu("JARVIS") {
                Button("Show Command Bar (⌃⌥J)") { CommandPanel.shared.toggle() }
                Button("Analyze Screen Now (⌃⌥S)") { MacAppDelegate.analyzeScreenNow() }
                Button(WatchModeController.shared.isWatching ? "Pause Screen Watch" : "Start Screen Watch") {
                    WatchModeController.shared.toggle()
                }
                Divider()
                Button("Open JARVIS Folder") { NSWorkspace.shared.open(Workspace.shared.root) }
            }
        }

        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .frame(width: 640, height: 660)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared

        // "Hey JARVIS" while the app is running.
        WakeWordListener.shared.onWake = { command in
            CommandPanel.shared.show()
            if command.isEmpty {
                ChatViewModel.shared.toggleListening()
            } else {
                ChatViewModel.shared.send(command)
            }
        }
        AppSettings.shared.$wakeWordEnabled
            .removeDuplicates()
            .sink { enabled in
                Task { @MainActor in WakeWordListener.shared.setEnabled(enabled) }
            }
            .store(in: &cancellables)

        // Writing to a pipe of a process that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)

        Workspace.shared.ensureExists()
        let chat = ChatViewModel.shared
        chat.platformTools = MacTools.all
        chat.screenCapturer = { try await ScreenCapture.captureAttachment() }
        chat.contextProvider = { ScreenCapture.contextLine() }

        let hotKeys = HotKeyManager.shared
        let modifiers = controlKey | optionKey
        hotKeys.register(keyCode: kVK_ANSI_J, modifiers: modifiers) {
            Task { @MainActor in CommandPanel.shared.toggle() }
        }
        hotKeys.register(keyCode: kVK_ANSI_S, modifiers: modifiers) {
            Task { @MainActor in MacAppDelegate.analyzeScreenNow() }
        }
        hotKeys.register(keyCode: kVK_ANSI_C, modifiers: modifiers) {
            Task { @MainActor in
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
                CommandPanel.shared.show()
                ChatViewModel.shared.send("Help me with this (from my clipboard) – explain, fix or improve it as appropriate:\n\n\(text.prefix(20_000))")
            }
        }
        hotKeys.register(keyCode: kVK_ANSI_V, modifiers: modifiers) {
            Task { @MainActor in
                CommandPanel.shared.show()
                if !ChatViewModel.shared.speech.isRecording { ChatViewModel.shared.toggleListening() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MacAppState.shared.showMainWindow(section: MacAppState.shared.section) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConversationStore.shared.save(ChatViewModel.shared.conversation)
    }

    static func analyzeScreenNow() {
        MacAppState.shared.showMainWindow(section: .watch)
        Task { await WatchModeController.shared.analyze(force: true) }
    }
}

@MainActor
final class MacAppState: ObservableObject {
    static let shared = MacAppState()

    enum Section: String, Hashable {
        case chat, watch, files, settings
    }

    @Published var section: Section = .chat
    var openMainWindow: (() -> Void)?

    func showMainWindow(section: Section) {
        self.section = section
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var watch = WatchModeController.shared
    @ObservedObject private var chat = ChatViewModel.shared

    var body: some View {
        Image(systemName: chat.isRunning || watch.isAnalyzing ? "circle.hexagongrid.circle.fill"
              : (watch.isWatching ? "eye.circle" : "circle.hexagongrid.circle"))
            .onAppear {
                MacAppState.shared.openMainWindow = { openWindow(id: "main") }
            }
    }
}

struct MacRootView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var state = MacAppState.shared
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var watch = WatchModeController.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var filesPath: [URL] = []

    private var selection: Binding<MacAppState.Section?> {
        Binding(get: { state.section }, set: { if let value = $0 { state.section = value } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("JARVIS") {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(MacAppState.Section.chat)
                    Label("Screen Watch", systemImage: watch.isWatching ? "eye.fill" : "eye")
                        .badge(watch.suggestions.count)
                        .tag(MacAppState.Section.watch)
                    Label("Files", systemImage: "folder").tag(MacAppState.Section.files)
                    Label("Settings", systemImage: "gearshape").tag(MacAppState.Section.settings)
                }
                Section("Conversations") {
                    ForEach(store.summaries.prefix(40)) { summary in
                        Button {
                            chat.open(summary.id)
                            state.section = .chat
                        } label: {
                            Text(summary.title)
                                .lineLimit(1)
                                .fontWeight(summary.id == chat.conversation.id ? .semibold : .regular)
                                .foregroundColor(summary.id == chat.conversation.id ? Theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { chat.delete(summary.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .onAppear {
            MacAppState.shared.openMainWindow = { openWindow(id: "main") }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .chat:
            ChatView(vm: chat, onOpenSettings: { state.section = .settings })
                .navigationTitle(chat.conversation.title)
                .navigationSubtitle(settings.provider.shortName)
                .toolbar {
                    ToolbarItemGroup {
                        Picker("Brain", selection: $settings.provider) {
                            ForEach(ProviderKind.available) { Text($0.shortName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .help("Which AI powers JARVIS")
                        Menu {
                            Button("Export as Markdown") { export(asPDF: false) }
                            Button("Export as PDF") { export(asPDF: true) }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(chat.conversation.messages.isEmpty)
                        Button {
                            chat.newConversation()
                        } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        }
                        .disabled(chat.isRunning)
                    }
                }
        case .watch:
            SuggestionsView()
                .navigationTitle("Screen Watch")
        case .files:
            NavigationStack(path: $filesPath) {
                WorkspaceBrowserView(folder: Workspace.shared.root, onAskAbout: askAbout)
                    .navigationDestination(for: URL.self) { url in
                        WorkspaceBrowserView(folder: url, onAskAbout: askAbout)
                    }
            }
        case .settings:
            MacSettingsView()
                .navigationTitle("Settings")
        }
    }

    private func askAbout(_ url: URL) {
        chat.attach(fileURL: url)
        chat.draft = "Look at \(url.lastPathComponent) and "
        state.section = .chat
    }

    private func export(asPDF: Bool) {
        let conversation = chat.conversation
        Task {
            if let url = try? await ConversationExporter.export(conversation, asPDF: asPDF) {
                chat.noteCreatedFiles([Workspace.shared.relativePath(of: url)])
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var watch = WatchModeController.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = ""

    private var lastReply: String? {
        chat.conversation.messages.last { $0.role == .assistant && !$0.isLocalNotice && !$0.visibleText.isEmpty }?.visibleText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CoreOrbView(mode: chat.isRunning || watch.isAnalyzing ? .thinking : .idle, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS").font(.headline)
                    Text(chat.isRunning ? (chat.status.isEmpty ? "Thinking…" : chat.status) : "\(settings.provider.shortName) · ready")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    MacAppState.shared.showMainWindow(section: .settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }

            HStack {
                TextField("Ask JARVIS…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.accent)
                    .disabled(chat.isRunning)
            }
            Toggle("Let JARVIS see my screen", isOn: $chat.includeScreen)
                .font(.caption)

            if let reply = lastReply {
                ScrollView {
                    Text(reply)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }

            Divider()

            HStack {
                Toggle("Screen Watch", isOn: Binding(get: { watch.isWatching }, set: { $0 ? watch.start() : watch.stop() }))
                    .toggleStyle(.switch)
                Spacer()
                Button("Analyze now") { Task { await watch.analyze(force: true) } }
                    .disabled(watch.isAnalyzing)
            }
            if !watch.statusMessage.isEmpty {
                Text(watch.statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            ForEach(watch.suggestions.prefix(3)) { suggestion in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: suggestion.actionIcon).foregroundColor(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title).font(.callout.weight(.semibold))
                        if !suggestion.detail.isEmpty {
                            Text(suggestion.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if let label = suggestion.actionLabel {
                        Button(label) { watch.perform(suggestion) }
                            .controlSize(.small)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open JARVIS") { MacAppState.shared.showMainWindow(section: .chat) }
                Button("Command bar") { CommandPanel.shared.show() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        text = ""
        chat.send(request)
    }
}
