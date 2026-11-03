import SwiftUI
import QuickLook

/// Full-screen voice & video conversation.
/// - Gemini Live / OpenAI Realtime: real-time, interruptible, sees the camera.
/// - Classic: works with every brain (Claude, GPT, local, on-device); the
///   camera view is attached as a photo each time you speak.
struct VoiceModeView: View {
    var initialText: String?
    var onClose: () -> Void

    @StateObject private var live = LiveVoiceSession()
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var speech = ChatViewModel.shared.speech
    @ObservedObject private var voice = VoiceOutput.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var approvals = ApprovalCenter.shared
    @State private var engine: LiveEngineKind = .classic
    @State private var started = false
    @State private var typing = false
    @State private var typedText = ""
    @State private var previewURL: URL?
    @State private var classicCameraOn = false

    private var isLive: Bool { engine != .classic }
    private var cameraOn: Bool { isLive ? live.cameraOn : classicCameraOn }

    var body: some View {
        ZStack {
            Theme.backgroundGradient
            VStack(spacing: 16) {
                header
                if cameraOn {
                    CameraPreview(session: live.camera.session)
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { live.flipCamera() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(10)
                        }
                        .overlay(alignment: .bottomLeading) {
                            Label(isLive ? "JARVIS can see this" : "Attached each time you speak", systemImage: "eye")
                                .font(.caption2)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(10)
                        }
                        .padding(.horizontal)
                }
                Spacer(minLength: 0)
                CoreOrbView(mode: orbMode, level: CGFloat(orbLevel), size: cameraOn ? 140 : 230)
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .animation(.easeInOut, value: statusText)
                if let notice = isLive ? live.notice : nil {
                    Text(notice).font(.caption).foregroundColor(Theme.warm).padding(.horizontal)
                }
                transcript
                if !files.isEmpty { fileStrip }
                Spacer(minLength: 0)
                if typing { typeBar }
                controls
            }
            .padding(.vertical)
        }
        .preferredColorScheme(.dark)
        .quickLookPreview($previewURL)
        .alert(
            approvals.pending?.title ?? "",
            isPresented: Binding(get: { approvals.pending != nil }, set: { _ in })
        ) {
            Button("Allow") { approvals.resolve(true) }
            Button("Deny", role: .cancel) { approvals.resolve(false) }
        } message: {
            Text(approvals.pending?.detail ?? "")
        }
        .task {
            guard !started else { return }
            started = true
            WakeWordListener.shared.pause()
            chat.stop()
            await begin(LiveEngineKind.resolve(settings), initialText: initialText)
        }
        .onDisappear {
            live.stop()
            live.camera.stop()
            chat.cameraSnapshot = nil
            if chat.voiceLoopActive { chat.stopVoiceLoop() }
            WakeWordListener.shared.resumeIfEnabled()
        }
    }

    // MARK: Engine switching

    private func begin(_ newEngine: LiveEngineKind, initialText: String? = nil) async {
        engine = newEngine
        if newEngine == .classic {
            chat.startVoiceLoop(initialText: initialText)
        } else {
            await live.start(engine: newEngine, initialText: initialText)
        }
    }

    private func switchEngine(_ newEngine: LiveEngineKind) {
        guard newEngine != engine else { return }
        let wasCameraOn = cameraOn
        live.stop()
        if chat.voiceLoopActive { chat.stopVoiceLoop() }
        if classicCameraOn { setClassicCamera(false) }
        settings.liveEngine = newEngine.rawValue
        Task {
            await begin(newEngine)
            if wasCameraOn { toggleCamera() }
        }
    }

    private func engineAvailable(_ kind: LiveEngineKind) -> Bool {
        switch kind {
        case .gemini: return settings.hasGeminiKey
        case .openai: return settings.hasOpenAIKey
        case .classic: return settings.isProviderConfigured
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Menu {
                ForEach(LiveEngineKind.allCases) { kind in
                    Button {
                        switchEngine(kind)
                    } label: {
                        if kind == engine {
                            Label(kind.title, systemImage: "checkmark")
                        } else {
                            Text(kind.title + (engineAvailable(kind) ? "" : " (needs key)"))
                        }
                    }
                    .disabled(!engineAvailable(kind))
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("JARVIS").font(.title3.weight(.bold)).foregroundColor(.white)
                        Image(systemName: "chevron.down").font(.caption).foregroundColor(Theme.secondaryText)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
    }

    private var subtitle: String {
        switch engine {
        case .classic: return "Classic · \(settings.provider.shortName)"
        default: return "\(engine.title) · \(live.modelName)"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(transcriptLines) { line in
                        HStack {
                            if line.isUser { Spacer(minLength: 40) }
                            Text(line.text)
                                .font(line.isUser ? Font.body : Font.body.weight(.medium))
                                .foregroundColor(line.isUser ? Theme.secondaryText : .white)
                                .multilineTextAlignment(line.isUser ? .trailing : .leading)
                            if !line.isUser { Spacer(minLength: 40) }
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 200)
            .onChange(of: transcriptLines.last?.text ?? "") { _, _ in
                if let last = transcriptLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var fileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files.prefix(8), id: \.self) { path in
                    FileChip(relativePath: path) { previewURL = $0 }
                        .frame(maxWidth: 220)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 120)
    }

    private var typeBar: some View {
        HStack {
            TextField("Type to JARVIS…", text: $typedText)
                .textFieldStyle(.plain)
                .padding(12)
                .hudPanel(cornerRadius: 18)
                .onSubmit(sendTyped)
            Button(action: sendTyped) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        HStack(spacing: 20) {
            controlButton(cameraOn ? "video.fill" : "video", active: cameraOn) { toggleCamera() }
            if isLive {
                controlButton(live.micMuted ? "mic.slash.fill" : "mic.fill", active: !live.micMuted) { live.micMuted.toggle() }
            } else {
                controlButton(speech.isRecording ? "mic.fill" : "mic", active: speech.isRecording) {
                    if speech.isRecording { chat.finishListening() } else { chat.toggleListening() }
                }
            }
            controlButton("keyboard", active: typing) { typing.toggle() }
            Button(action: close) {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 70, height: 70)
                    .background(Circle().fill(Color.red))
            }
            if isLive && liveFailed {
                controlButton("arrow.clockwise", active: false) {
                    Task { await live.start(engine: engine) }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func controlButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(active ? Theme.background : .white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(active ? Theme.accent : Color.white.opacity(0.14)))
        }
    }

    // MARK: Camera

    private func toggleCamera() {
        if isLive {
            live.toggleCamera()
        } else {
            setClassicCamera(!classicCameraOn)
        }
    }

    private func setClassicCamera(_ on: Bool) {
        if on {
            Task {
                if await live.camera.start() {
                    classicCameraOn = true
                    let camera = live.camera
                    chat.cameraSnapshot = { camera.latestAttachment }
                }
            }
        } else {
            live.camera.stop()
            classicCameraOn = false
            chat.cameraSnapshot = nil
        }
    }

    // MARK: State

    private struct TranscriptLine: Identifiable {
        let id: String
        let isUser: Bool
        let text: String
    }

    private var transcriptLines: [TranscriptLine] {
        if isLive {
            return live.lines.suffix(8).map { TranscriptLine(id: $0.id.uuidString, isUser: $0.isUser, text: $0.text) }
        }
        var result: [TranscriptLine] = chat.conversation.messages.suffix(8).compactMap { message in
            guard !message.isLocalNotice, message.role != .tool else { return nil }
            let text = message.visibleText
            guard !text.isEmpty else { return nil }
            return TranscriptLine(id: message.id.uuidString, isUser: message.role == .user, text: text)
        }
        if speech.isRecording, !speech.transcript.isEmpty {
            result.append(TranscriptLine(id: "live-transcript", isUser: true, text: speech.transcript))
        }
        if let streaming = chat.streamingText, !streaming.isEmpty {
            result.append(TranscriptLine(id: "streaming", isUser: false, text: streaming))
        }
        return result
    }

    private var liveFailed: Bool {
        if case .failed = live.phase { return true }
        return false
    }

    private var files: [String] { isLive ? live.createdFiles : Array(chat.recentFiles.prefix(8)) }

    private var orbMode: CoreOrbView.Mode {
        if isLive {
            switch live.phase {
            case .connecting, .reconnecting, .working: return .thinking
            case .speaking: return .speaking
            case .listening: return .listening
            default: return .idle
            }
        }
        if speech.isRecording { return .listening }
        if chat.isRunning { return .thinking }
        if voice.isSpeaking { return .speaking }
        return .idle
    }

    private var orbLevel: Float {
        if isLive { return max(live.inputLevel, live.outputLevel) }
        return max(speech.level, voice.level)
    }

    private var statusText: String {
        if isLive {
            switch live.phase {
            case .idle, .connecting: return "Connecting…"
            case .reconnecting: return "Reconnecting…"
            case .listening: return live.micMuted ? "Muted" : "Listening…"
            case .speaking: return "Speaking – just talk to interrupt"
            case .working(let label): return "\(label)…"
            case .ended: return "Call ended"
            case .failed(let message): return message
            }
        }
        if speech.isRecording { return "Listening…" }
        if chat.isRunning { return chat.status.isEmpty ? "Thinking…" : chat.status }
        if voice.isPreparing { return "Finding the words…" }
        if voice.isSpeaking { return "Speaking…" }
        return "Tap the mic to talk"
    }

    private func sendTyped() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedText = ""
        if isLive { live.sendText(text) } else { chat.send(text) }
    }

    private func close() {
        live.stop()
        live.camera.stop()
        chat.cameraSnapshot = nil
        if chat.voiceLoopActive { chat.stopVoiceLoop() }
        onClose()
    }
}
