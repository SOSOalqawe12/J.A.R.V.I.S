import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject private var speech: SpeechRecognizer
    @ObservedObject private var voice = VoiceOutput.shared
    @ObservedObject private var settings = AppSettings.shared
    var onOpenSettings: () -> Void = {}
    /// Opens the full-screen voice mode (iOS). Nil = use the mic button only.
    var onStartVoice: (() -> Void)?

    @State private var previewURL: URL?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @FocusState private var inputFocused: Bool

    init(vm: ChatViewModel, onOpenSettings: @escaping () -> Void = {}, onStartVoice: (() -> Void)? = nil) {
        self.vm = vm
        self._speech = ObservedObject(wrappedValue: vm.speech)
        self.onOpenSettings = onOpenSettings
        self.onStartVoice = onStartVoice
    }

    var body: some View {
        VStack(spacing: 0) {
            if !settings.isProviderConfigured { setupBanner }
            messages
            composer
        }
        .background(Theme.backgroundGradient)
        .quickLookPreview($previewURL)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { vm.attach(fileURL: url) }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let type = item.supportedContentTypes.first
                        vm.attach(data: data, name: "Photo.\(type?.preferredFilenameExtension ?? "jpg")",
                                  mimeType: type?.preferredMIMEType ?? "image/jpeg")
                    }
                }
                photoItems = []
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $vm.showScanner) {
            DocumentScannerView { images in
                vm.showScanner = false
                Task { await ScanSaver.save(images, into: vm) }
            } onCancel: {
                vm.showScanner = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $vm.showCamera) {
            CameraPicker { image in
                vm.showCamera = false
                if let image, let data = image.jpegData(compressionQuality: 0.9) {
                    vm.attach(data: data, name: "Camera.jpg", mimeType: "image/jpeg")
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    // MARK: Setup banner

    private var setupBanner: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                Text(setupMessage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundColor(Theme.background)
            .padding(12)
            .background(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.conversation.messages.filter({ !$0.isLocalNotice }).isEmpty {
                        welcome
                    }
                    ForEach(vm.conversation.messages) { message in
                        MessageRow(
                            message: message,
                            onOpen: { previewURL = $0 },
                            onRetry: retryAction(for: message),
                            onRegenerate: regenerateAction(for: message)
                        )
                        .id(message.id)
                    }
                    if let streaming = vm.streamingText, !streaming.isEmpty {
                        StreamingBubble(text: streaming)
                            .id("streaming")
                    }
                    if vm.isRunning {
                        ThinkingRow(status: vm.status, onStop: { vm.stop() })
                            .id("thinking")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.isRunning) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.streamingText?.count ?? 0) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var setupMessage: String {
        switch settings.provider {
        case .claude: return "Add your Claude API key to wake me up."
        case .openai: return "Add your OpenAI API key to wake me up."
        case .local: return "Set your local server address in Settings."
        case .apple: return "Apple Intelligence isn't available on this device – pick another brain."
        case .deepseek: return "Add your DeepSeek API key to wake me up."
        default: return "Add your Gemini API key to wake me up."
        }
    }

    private var showsVoiceButton: Bool {
        onStartVoice != nil && !vm.isRunning && vm.pendingAttachments.isEmpty
            && vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func regenerateAction(for message: ChatMessage) -> (() -> Void)? {
        guard message.role == .assistant, !message.isLocalNotice, vm.canRegenerate,
              message.id == vm.conversation.messages.last(where: { $0.role == .assistant && !$0.isLocalNotice })?.id
        else { return nil }
        let model = vm
        return { model.regenerate() }
    }

    private func retryAction(for message: ChatMessage) -> (() -> Void)? {
        guard message.id == vm.conversation.messages.last?.id, message.isLocalNotice, !vm.isRunning,
              message.visibleText.hasPrefix("⚠️") else { return nil }
        let model = vm
        return { model.retry() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Working late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = settings.userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            CoreOrbView(mode: speech.isRecording ? .listening : .idle, level: CGFloat(speech.level), size: 150)
                .padding(.top, 24)
            Text(greeting)
                .font(.title2.weight(.semibold))
                .foregroundColor(Theme.text)
            Text("Tell me what to make. Everything I create is saved in your JARVIS folder.")
                .font(.subheadline)
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    if let onStartVoice { onStartVoice() } else { vm.toggleListening() }
                } label: {
                    Label("Talk to JARVIS", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundColor(Theme.background)
                .disabled(!settings.isProviderConfigured)
                Menu {
                    ForEach(AssistantMode.allCases) { mode in
                        Button {
                            vm.newConversation(mode: mode)
                        } label: {
                            Label(mode.title, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Label(vm.currentMode.title, systemImage: vm.currentMode.icon)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .hudPanel(cornerRadius: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(ChatViewModel.quickPrompts) { prompt in
                    Button {
                        vm.send(prompt.text)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: prompt.icon).foregroundColor(Theme.accent).frame(width: 20)
                            Text(prompt.text)
                                .font(.footnote)
                                .foregroundColor(Theme.text)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hudPanel(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!settings.isProviderConfigured)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !vm.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.pendingAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                AttachmentPreview(attachment: attachment)
                                    .frame(maxHeight: 70)
                                Button {
                                    vm.pendingAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            if speech.isRecording {
                HStack(spacing: 10) {
                    CoreOrbView(mode: .listening, level: CGFloat(speech.level), size: 30)
                    Text(speech.transcript.isEmpty ? (settings.autoSendVoice ? "Listening… (sends when you stop talking)" : "Listening…") : speech.transcript)
                        .font(.subheadline)
                        .foregroundColor(Theme.text)
                        .lineLimit(3)
                    Spacer()
                    Button(settings.autoSendVoice ? "Send" : "Done") { vm.finishListening() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .padding(.horizontal, 16)
            }
            if let error = speech.errorMessage {
                Text(error).font(.caption).foregroundColor(Theme.warm).padding(.horizontal, 16)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    #if os(iOS)
                    Button {
                        vm.showCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera")
                    }
                    if DocumentScannerView.isSupported {
                        Button {
                            vm.showScanner = true
                        } label: {
                            Label("Scan document", systemImage: "doc.viewfinder")
                        }
                    }
                    #endif
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.accent)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                #if os(macOS)
                Button {
                    vm.includeScreen.toggle()
                } label: {
                    Image(systemName: vm.includeScreen ? "eye.fill" : "eye.slash")
                        .font(.system(size: 20))
                        .foregroundColor(vm.includeScreen ? Theme.accent : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(vm.includeScreen ? "JARVIS will see your screen with each message" : "Let JARVIS see your screen")
                #endif

                TextField("Ask JARVIS to make something…", text: $vm.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundColor(Theme.text)
                    .hudPanel(cornerRadius: 20)
                    .onSubmit { vm.send() }

                Button {
                    vm.toggleListening()
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 22))
                        .foregroundColor(speech.isRecording ? Theme.warm : Theme.accent)
                        .frame(width: 32, height: 36)
                }
                .buttonStyle(.plain)

                if let onStartVoice, showsVoiceButton {
                    Button(action: onStartVoice) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voice mode")
                }

                if vm.isRunning {
                    Button { vm.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundColor(Theme.warm)
                    }
                    .buttonStyle(.plain)
                } else if !showsVoiceButton {
                    Button { vm.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.pendingAttachments.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .background(Theme.background.opacity(0.94))
    }
}

/// Conversation history list (sheet on iOS, sidebar section on macOS).
struct ConversationListView: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var store = ConversationStore.shared
    var onSelect: () -> Void = {}
    @State private var query = ""

    private var filtered: [ConversationSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return store.summaries }
        return store.summaries.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List {
            Button {
                vm.newConversation()
                onSelect()
            } label: {
                Label("New conversation", systemImage: "plus.bubble")
            }
            ForEach(filtered) { summary in
                Button {
                    vm.open(summary.id)
                    onSelect()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if summary.origin == "siri" || summary.origin == "voice" { Image(systemName: "mic.circle") }
                            Text(summary.title).lineLimit(1)
                        }
                        Text(summary.updated, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { vm.delete(summary.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { filtered[$0].id }
                for id in ids { vm.delete(id) }
            }
        }
        .searchable(text: $query, prompt: "Search conversations")
    }
}
