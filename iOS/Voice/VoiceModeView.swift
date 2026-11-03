import SwiftUI
import QuickLook

/// Full-screen voice conversation. Uses Gemini Live (real-time, interruptible)
/// when available, otherwise the classic listen → think → speak loop.
struct VoiceModeView: View {
    var initialText: String?
    var onClose: () -> Void

    @StateObject private var live = LiveVoiceSession()
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var speech = ChatViewModel.shared.speech
    @ObservedObject private var voice = VoiceOutput.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var approvals = ApprovalCenter.shared
    @State private var useLive = true
    @State private var started = false
    @State private var typing = false
    @State private var typedText = ""
    @State private var previewURL: URL?

    private var liveAvailable: Bool { settings.liveVoiceEnabled && settings.hasGeminiKey }

    var body: some View {
        ZStack {
            Theme.backgroundGradient
            VStack(spacing: 18) {
                header
                if useLive && live.cameraOn {
                    CameraPreview(session: live.camera.session)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { live.flipCamera() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(10)
                        }
                        .padding(.horizontal)
                }
                Spacer(minLength: 0)
                CoreOrbView(mode: orbMode, level: CGFloat(orbLevel), size: live.cameraOn ? 150 : 230)
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(Theme.secondaryText)
                    .animation(.easeInOut, value: statusText)
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
            if liveAvailable {
                useLive = true
                await live.start(initialText: initialText)
            } else {
                startClassic()
            }
        }
        .onDisappear {
            live.stop()
            if chat.voiceLoopActive { chat.stopVoiceLoop() }
            WakeWordListener.shared.resumeIfEnabled()
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS").font(.title3.weight(.bold)).foregroundColor(.white)
                Text(useLive ? "Live · \(live.modelName.isEmpty ? "Gemini" : live.modelName)" : "Voice · \(settings.provider.shortName)")
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
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
            .frame(maxHeight: 220)
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
        HStack(spacing: 22) {
            if useLive {
                controlButton(live.cameraOn ? "video.fill" : "video", active: live.cameraOn) { live.toggleCamera() }
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
            if useLive && liveFailed {
                controlButton("arrow.triangle.2.circlepath", active: false) {
                    useLive = false
                    startClassic()
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
                .frame(width: 58, height: 58)
                .background(Circle().fill(active ? Theme.accent : Color.white.opacity(0.14)))
        }
    }

    // MARK: State

    private struct TranscriptLine: Identifiable {
        let id: String
        let isUser: Bool
        let text: String
    }

    private var transcriptLines: [TranscriptLine] {
        if useLive {
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

    private var files: [String] { useLive ? live.createdFiles : Array(chat.recentFiles.prefix(8)) }

    private var orbMode: CoreOrbView.Mode {
        if useLive {
            switch live.phase {
            case .connecting, .working: return .thinking
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
        if useLive { return max(live.inputLevel, live.outputLevel) }
        return max(speech.level, voice.level)
    }

    private var statusText: String {
        if useLive {
            switch live.phase {
            case .idle, .connecting: return "Connecting…"
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

    private func startClassic() {
        live.stop()
        chat.startVoiceLoop(initialText: initialText)
    }

    private func sendTyped() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedText = ""
        if useLive { live.sendText(text) } else { chat.send(text) }
    }

    private func close() {
        live.stop()
        if chat.voiceLoopActive { chat.stopVoiceLoop() }
        onClose()
    }
}
