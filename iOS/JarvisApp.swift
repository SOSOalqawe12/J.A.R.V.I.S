import SwiftUI

@main
struct JarvisApp: App {
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
                ConversationStore.shared.save(ChatViewModel.shared.conversation)
            case .active:
                lock.unlockIfNeeded()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case chat, files, settings }

    @EnvironmentObject private var lock: AppLock
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var approvals = ApprovalCenter.shared
    @State private var tab: Tab = .chat
    @State private var showHistory = false
    @State private var filesPath: [URL] = []

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                NavigationStack {
                    ChatView(vm: chat, onOpenSettings: { tab = .settings })
                        .navigationTitle(chat.conversation.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { chat.newConversation() } label: { Image(systemName: "square.and.pencil") }
                                    .disabled(chat.isRunning)
                            }
                        }
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
            .alert(
                approvals.pending?.title ?? "",
                isPresented: Binding(get: { approvals.pending != nil }, set: { _ in })
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
        .onOpenURL { url in
            // jarvis://ask?q=... lets other apps/Shortcuts start a request.
            guard url.scheme == "jarvis",
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
            else { return }
            tab = .chat
            chat.send(query)
        }
    }

    private func askAbout(_ url: URL) {
        chat.attach(fileURL: url)
        chat.draft = "Look at \(url.lastPathComponent) and "
        tab = .chat
    }
}
