import SwiftUI

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(JarvisAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lock = AppLock()

    init() {
        ChatViewModel.shared.platformTools = iOSTools.all
        Workspace.shared.ensureExists()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lock)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.lockIfNeeded()
                WakeWordListener.shared.pause()
                ConversationStore.shared.save(ChatViewModel.shared.conversation)
            case .active:
                lock.unlockIfNeeded()
                if AppSettings.shared.wakeWordEnabled { WakeWordListener.shared.setEnabled(true) }
            default:
                break
            }
        }
    }
}

struct VoicePresentation: Identifiable {
    let id = UUID()
    let initialText: String?
}

struct RootView: View {
    enum Tab: Hashable { case chat, files, settings }

    @EnvironmentObject private var lock: AppLock
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var wake = WakeWordListener.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var tab: Tab = .chat
    @State private var showHistory = false
    @State private var filesPath: [URL] = []
    @State private var voice: VoicePresentation?
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                NavigationStack {
                    ChatView(vm: chat, onOpenSettings: { tab = .settings }, onStartVoice: { startVoice(nil) })
                        .navigationTitle(chat.conversation.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { chatToolbar }
                        .toolbarBackground(Theme.background, for: .navigationBar)
                }
                .tabItem { Label("JARVIS", systemImage: "circle.hexagongrid.circle") }
                .tag(Tab.chat)

                NavigationStack(path: $filesPath) {
                    WorkspaceBrowserView(folder: Workspace.shared.root, onAskAbout: askAbout)
                        .navigationDestination(for: URL.self) { url in
                            WorkspaceBrowserView(folder: url, onAskAbout: askAbout)
                        }
                }
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(Tab.files)

                NavigationStack {
                    SettingsView()
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    ConversationListView(vm: chat, onSelect: { showHistory = false })
                        .navigationTitle("Conversations")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showHistory = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: $voice) { presentation in
                VoiceModeView(initialText: presentation.initialText) { voice = nil }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView { showOnboarding = false }
            }
            .alert(
                approvals.pending?.title ?? "",
                isPresented: Binding(get: { approvals.pending != nil && voice == nil }, set: { _ in })
            ) {
                Button("Allow") { approvals.resolve(true) }
                Button("Deny", role: .cancel) { approvals.resolve(false) }
            } message: {
                Text(approvals.pending?.detail ?? "")
            }

            if lock.isLocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .onOpenURL(perform: openURL)
        .onChange(of: router.pending) { _, action in handle(action) }
        .onAppear {
            if !settings.onboardingDone {
                if settings.isProviderConfigured { settings.onboardingDone = true } else { showOnboarding = true }
            }
            handle(router.pending)
            WakeWordListener.shared.onWake = { command in
                startVoice(command.isEmpty ? nil : command)
            }
            if settings.wakeWordEnabled { WakeWordListener.shared.setEnabled(true) }
        }
        .onChange(of: settings.wakeWordEnabled) { _, enabled in
            WakeWordListener.shared.setEnabled(enabled)
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
        }
        ToolbarItem(placement: .principal) {
            if wake.isListening {
                Label("Say “Hey JARVIS”", systemImage: "ear")
                    .font(.caption)
                    .foregroundColor(Theme.accent)
            } else {
                Text(chat.conversation.title).font(.headline).lineLimit(1)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(AssistantMode.allCases) { mode in
                    Button {
                        chat.newConversation(mode: mode)
                    } label: {
                        Label("New \(mode.title) chat", systemImage: mode.icon)
                    }
                }
            } label: {
                Image(systemName: chat.currentMode.icon)
            }
            Menu {
                Button { chat.newConversation(mode: chat.currentMode) } label: { Label("New chat", systemImage: "square.and.pencil") }
                Button { export(asPDF: false) } label: { Label("Export as Markdown", systemImage: "doc.plaintext") }
                Button { export(asPDF: true) } label: { Label("Export as PDF", systemImage: "doc.richtext") }
                Button { chat.send(ChatViewModel.briefingPrompt) } label: { Label("Daily briefing", systemImage: "sun.max") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(chat.isRunning)
        }
    }

    private func export(asPDF: Bool) {
        let conversation = chat.conversation
        guard !conversation.messages.isEmpty else { return }
        Task {
            if let url = try? await ConversationExporter.export(conversation, asPDF: asPDF) {
                chat.noteCreatedFiles([Workspace.shared.relativePath(of: url)])
                _ = await SheetPresenter.shared.share([url])
            }
        }
    }

    private func startVoice(_ initialText: String?) {
        guard voice == nil else { return }
        tab = .chat
        voice = VoicePresentation(initialText: initialText)
    }

    private func handle(_ action: AppRouter.Action?) {
        guard let action else { return }
        router.pending = nil
        switch action {
        case .voice(let text):
            startVoice(text)
        case .newChat:
            tab = .chat
            chat.newConversation()
        case .briefing:
            tab = .chat
            chat.send(ChatViewModel.briefingPrompt)
        case .scan:
            tab = .chat
            chat.showScanner = true
        case .ask(let text):
            tab = .chat
            chat.send(text)
        case .attach(let url):
            tab = .chat
            chat.attach(fileURL: url)
            if chat.draft.isEmpty { chat.draft = "Look at \(url.lastPathComponent) and " }
        case .files:
            tab = .files
        }
    }

    /// jarvis://ask?q=…, jarvis://voice, jarvis://briefing, jarvis://scan, or a shared file.
    private func openURL(_ url: URL) {
        if url.isFileURL {
            handle(.attach(url))
            return
        }
        guard url.scheme == "jarvis" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
        switch url.host {
        case "voice": handle(.voice(query))
        case "briefing": handle(.briefing)
        case "scan": handle(.scan)
        case "files": handle(.files)
        default:
            if let query { handle(.ask(query)) }
        }
    }

    private func askAbout(_ url: URL) {
        chat.attach(fileURL: url)
        chat.draft = "Look at \(url.lastPathComponent) and "
        tab = .chat
    }
}
