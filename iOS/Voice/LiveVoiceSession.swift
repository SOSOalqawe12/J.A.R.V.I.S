import Foundation
import AVFoundation
import CoreImage
import SwiftUI

/// A real-time, interruptible voice (and video) conversation over Gemini Live
/// or OpenAI Realtime. JARVIS hears you continuously, answers with a natural
/// voice, can be interrupted, uses all its tools while talking, sees through
/// the camera, and reconnects transparently when the server rotates sessions.
@MainActor
final class LiveVoiceSession: ObservableObject {
    struct Line: Identifiable, Hashable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    enum Phase: Equatable {
        case idle, connecting, reconnecting, listening, speaking, working(String), ended, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [Line] = []
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var createdFiles: [String] = []
    @Published private(set) var cameraOn = false
    @Published private(set) var modelName = ""
    @Published private(set) var engine: LiveEngineKind = .gemini
    @Published private(set) var notice: String?
    @Published var micMuted = false {
        didSet { audio.muted = micMuted }
    }
    @Published var speakerOn = true {
        didSet { audio.setSpeaker(speakerOn) }
    }

    let camera = CameraFrameSource()
    private let audio = LiveAudioIO()
    private var transport: LiveTransport?
    private var socket: URLSessionWebSocketTask?
    private var connectionID = 0
    private var ready = false
    private var everReady = false
    private var resumeHandle: String?
    private var reconnectAttempts = 0
    private var minimalSetup = false
    private var userEnded = false
    private var tools: [String: AgentTool] = [:]
    private var toolSpecs: [ToolSpec] = []
    private var systemPrompt = ""
    private var initialText: String?
    private var openUserLine: Int?
    private var openModelLine: Int?
    private let settings = AppSettings.shared

    var isActive: Bool {
        switch phase {
        case .connecting, .reconnecting, .listening, .speaking, .working: return true
        default: return false
        }
    }

    // MARK: Lifecycle

    func start(engine: LiveEngineKind, initialText: String? = nil) async {
        guard !isActive, engine != .classic else { return }
        self.engine = engine
        phase = .connecting
        lines = []
        createdFiles = []
        notice = nil
        openUserLine = nil
        openModelLine = nil
        ready = false
        everReady = false
        resumeHandle = nil
        reconnectAttempts = 0
        minimalSetup = false
        userEnded = false
        self.initialText = initialText

        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings › JARVIS.")
            return
        }

        switch engine {
        case .gemini:
            guard settings.hasGeminiKey else { phase = .failed("Gemini Live needs a Gemini API key."); return }
            let model: String
            if settings.geminiLiveModel.isEmpty {
                let models = await GeminiModelCatalog.shared.models(apiKey: settings.geminiAPIKey)
                model = GeminiModelPicker.best(models, for: .live) ?? GeminiModelPicker.fallbackLive
            } else {
                model = settings.geminiLiveModel
            }
            modelName = model
            transport = GeminiLiveTransport(apiKey: settings.geminiAPIKey, model: model, voice: settings.geminiVoiceName)
        case .openai:
            guard settings.hasOpenAIKey else { phase = .failed("OpenAI Realtime needs an OpenAI API key."); return }
            modelName = settings.openAIRealtimeModel
            transport = OpenAIRealtimeTransport(apiKey: settings.openAIAPIKey, model: settings.openAIRealtimeModel, voice: settings.openAIRealtimeVoice)
        case .classic:
            return
        }

        let allTools = Toolbox.sharedTools() + iOSTools.all
        tools = allTools.reduce(into: [:]) { $0[$1.name] = $1 }
        toolSpecs = allTools.map(\.spec)
        systemPrompt = SystemPrompts.make(settings: settings) + """


        # Live voice conversation
        You are speaking out loud in a real-time conversation. Keep replies short, warm and natural – usually one to \
        three sentences – unless the user asks for detail. Never read out markdown, code, file contents or long URLs. \
        Before using a tool, say a few words about what you're doing. When the camera is on you receive images of what \
        the user is looking at – describe or use them when relevant.
        """
        await connect()
    }

    func stop() {
        guard phase != .ended else { return }
        userEnded = true
        connectionID += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio.stop()
        if cameraOn { toggleCamera() }
        let hadConversation = everReady
        phase = .ended
        if hadConversation { saveTranscript() }
    }

    private func fail(_ message: String) {
        connectionID += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        audio.stop()
        if everReady { saveTranscript() }
        phase = .failed(message)
    }

    // MARK: Connection

    private func connect() async {
        guard let transport, !userEnded else { return }
        connectionID += 1
        let id = connectionID
        ready = false
        socket?.cancel(with: .goingAway, reason: nil)
        do {
            let socket = URLSession.shared.webSocketTask(with: try transport.connectRequest())
            socket.maximumMessageSize = 32 * 1024 * 1024
            self.socket = socket
            socket.resume()
            let messages = transport.setupMessages(system: systemPrompt, tools: toolSpecs, resumeHandle: resumeHandle, minimal: minimalSetup)
            for message in messages {
                try await socket.send(.string(message.jsonString()))
            }
            Task { [weak self] in await self?.receiveLoop(socket: socket, id: id) }
        } catch {
            await connectionLost(error.localizedDescription, id: id)
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, id: Int) async {
        while id == connectionID {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard id == connectionID, let json = try? JSONValue.parse(data), let transport else { continue }
                for event in transport.parse(json) {
                    guard id == connectionID else { return }
                    await handle(event)
                }
            } catch {
                guard id == connectionID else { return }
                let reason = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                await connectionLost(reason.isEmpty ? error.localizedDescription : reason, id: id)
                return
            }
        }
    }

    private func connectionLost(_ reason: String, id: Int) async {
        guard id == connectionID, !userEnded, let transport else { return }
        let lower = reason.lowercased()
        // The server rejected an optional setup field: retry once with the bare minimum.
        if !everReady, !minimalSetup, (lower.contains("invalid") || lower.contains("unknown") || lower.contains("field")) {
            minimalSetup = true
            await connect()
            return
        }
        // A working session dropped (time limit, network blip): reconnect.
        if everReady, reconnectAttempts < 3, !LiveVoiceSession.isQuotaError(lower) {
            reconnectAttempts += 1
            phase = .reconnecting
            if !transport.supportsResumption {
                notice = "Reconnected – earlier context may be lost."
            }
            try? await Task.sleep(nanoseconds: UInt64(reconnectAttempts) * 600_000_000)
            await connect()
            return
        }
        fail(friendlyError(reason))
    }

    static func isQuotaError(_ lower: String) -> Bool {
        lower.contains("quota") || lower.contains("resource_exhausted") || lower.contains("resource exhausted")
            || lower.contains("rate limit") || lower.contains("billing") || lower.contains("exceeded")
    }

    private func friendlyError(_ reason: String) -> String {
        let lower = reason.lowercased()
        let other = engine == .gemini ? "OpenAI Realtime" : "Gemini Live"
        if LiveVoiceSession.isQuotaError(lower) {
            return "The \(engine.title) quota for your key is used up for now. Switch to \(other) or Classic mode with the menu at the top, or try again later."
        }
        if lower.contains("not found") || lower.contains("not supported") || lower.contains("does not exist") || lower.contains("model") {
            return "The model \(modelName) isn't available for live voice with your key. Pick another one in Settings › Voice, or switch engine at the top. (\(reason.prefix(160)))"
        }
        if lower.contains("api key") || lower.contains("unauthorized") || lower.contains("permission") || lower.contains("401") || lower.contains("403") {
            return "The API key was rejected for live voice. Check it in Settings. (\(reason.prefix(160)))"
        }
        return "The live session ended: \(reason.isEmpty ? "connection closed" : String(reason.prefix(200)))"
    }

    // MARK: Events

    private func handle(_ event: LiveEvent) async {
        switch event {
        case .ready:
            ready = true
            everReady = true
            reconnectAttempts = 0
            if !audio.isRunning { beginAudio() }
            if case .reconnecting = phase { notice = notice ?? "Reconnected." }
            phase = .listening
            if let text = initialText, !text.isEmpty {
                initialText = nil
                sendText(text)
            }
        case .audio(let pcm):
            audio.play(pcm16: pcm)
            if case .working = phase {} else { phase = .speaking }
        case .userTranscript(let text):
            appendUser(text)
        case .modelTranscript(let text):
            appendModel(text)
        case .userStartedSpeaking:
            // OpenAI: give the model a look at the scene whenever the user talks.
            if let transport, !transport.streamsFramesContinuously, cameraOn, let jpeg = camera.latestJPEG {
                send(transport.frameMessages(jpeg))
            }
        case .interrupted:
            audio.flushPlayback()
            closeLines()
            if phase == .speaking { phase = .listening }
        case .turnComplete:
            closeLines()
            if !audio.isPlaying, phase == .speaking { phase = .listening }
        case .toolCalls(let calls):
            await runTools(calls)
        case .resumptionHandle(let handle):
            resumeHandle = handle
        case .goAway:
            // The server will close soon; hop to a fresh connection now.
            if transport?.supportsResumption == true, resumeHandle != nil {
                phase = .reconnecting
                await connect()
            }
        case .error(let message):
            if ready {
                notice = message
            } else {
                await connectionLost(message, id: connectionID)
            }
        }
    }

    private func beginAudio() {
        audio.onMicrophoneChunk = { @Sendable [weak self] chunk in
            Task { @MainActor in self?.sendAudio(chunk) }
        }
        audio.onInputLevel = { @Sendable [weak self] level in
            Task { @MainActor in self?.inputLevel = level }
        }
        audio.onOutputLevel = { @Sendable [weak self] level in
            Task { @MainActor in self?.outputLevel = level }
        }
        audio.onPlaybackDrained = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.outputLevel = 0
                if self.phase == .speaking { self.phase = .listening }
            }
        }
        do {
            try audio.start(micSampleRate: transport?.micSampleRate ?? 16_000)
            audio.muted = micMuted
            audio.setSpeaker(speakerOn)
            Haptics.success()
        } catch {
            fail("Audio couldn't start: \(error.localizedDescription)")
        }
    }

    // MARK: Outgoing

    private func send(_ messages: [JSONValue]) {
        guard let socket else { return }
        Task {
            for message in messages {
                try? await socket.send(.string(message.jsonString()))
            }
        }
    }

    private func sendAudio(_ pcm: Data) {
        guard ready, let transport else { return }
        send([transport.audioMessage(pcm)])
    }

    private func sendFrame(_ jpeg: Data) {
        guard ready, cameraOn, let transport, transport.streamsFramesContinuously else { return }
        send(transport.frameMessages(jpeg))
    }

    func sendText(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, ready, let transport else { return }
        lines.append(Line(isUser: true, text: clean))
        openUserLine = nil
        if cameraOn, let jpeg = camera.latestJPEG, !transport.streamsFramesContinuously {
            send(transport.frameMessages(jpeg))
        }
        send(transport.textMessages(clean))
    }

    func toggleCamera() {
        if cameraOn {
            camera.stop()
            cameraOn = false
            return
        }
        Task {
            camera.onFrame = { @Sendable [weak self] jpeg in
                Task { @MainActor in self?.sendFrame(jpeg) }
            }
            if await camera.start() {
                cameraOn = true
                notice = nil
                // Starting the camera can reconfigure audio; make sure the call is still audible.
                try? await Task.sleep(nanoseconds: 600_000_000)
                audio.recover()
            } else {
                notice = camera.lastError ?? "The camera couldn't start."
            }
        }
    }

    func flipCamera() { camera.flip() }

    // MARK: Tools

    private func runTools(_ calls: [LiveToolCall]) async {
        let context = ToolContext(workspace: .shared, settings: settings, approvals: ApprovalCenter.shared)
        var results: [LiveToolResult] = []
        for call in calls {
            let tool = tools[call.name]
            phase = .working(tool?.activityLabel ?? call.name)
            guard let tool else {
                results.append(LiveToolResult(call: call, output: "Unknown tool \(call.name)", isError: true))
                continue
            }
            do {
                let output = try await tool.run(call.arguments, context: context)
                if !output.files.isEmpty {
                    createdFiles.insert(contentsOf: output.files, at: 0)
                    ChatViewModel.shared.noteCreatedFiles(output.files)
                }
                results.append(LiveToolResult(call: call, output: output.text, isError: false))
            } catch {
                results.append(LiveToolResult(call: call, output: error.localizedDescription, isError: true))
            }
        }
        if let transport { send(transport.toolResultMessages(results)) }
        phase = audio.isPlaying ? .speaking : .listening
    }

    // MARK: Transcript

    private func appendUser(_ text: String) {
        openModelLine = nil
        if let index = openUserLine, lines.indices.contains(index) {
            lines[index].text += text
        } else {
            lines.append(Line(isUser: true, text: text.trimmingCharacters(in: .whitespaces)))
            openUserLine = lines.count - 1
        }
    }

    private func appendModel(_ text: String) {
        openUserLine = nil
        if let index = openModelLine, lines.indices.contains(index) {
            lines[index].text += text
        } else {
            lines.append(Line(isUser: false, text: text.trimmingCharacters(in: .whitespaces)))
            openModelLine = lines.count - 1
        }
    }

    private func closeLines() {
        openUserLine = nil
        openModelLine = nil
    }

    /// Keeps a text copy of the call in the conversation history.
    private func saveTranscript() {
        let spoken = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !spoken.isEmpty else { return }
        var conversation = Conversation(systemPrompt: SystemPrompts.make(settings: settings))
        conversation.origin = "voice"
        let firstUser = spoken.first(where: \.isUser)?.text ?? "Voice conversation"
        conversation.title = "🎙 " + ChatViewModel.title(for: firstUser, attachments: [])
        conversation.messages = spoken.map { line in
            ChatMessage(role: line.isUser ? .user : .assistant, parts: [.text(line.text)])
        }
        if !createdFiles.isEmpty {
            conversation.messages.append(.notice("Files created during the call: " + createdFiles.joined(separator: ", ")))
        }
        ConversationStore.shared.save(conversation)
    }
}

/// Camera frames for live vision: small JPEGs, sent only when the scene changes
/// (at most one per second, at least one every five seconds).
final class CameraFrameSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFrame: ((Data) -> Void)?
    private(set) var lastError: String?

    private let queue = DispatchQueue(label: "jarvis.camera")
    private let context = CIContext()
    private let lock = NSLock()
    private var lastSent = Date.distantPast
    private var lastProcessed = Date.distantPast
    private var lastFingerprint: [UInt8]?
    private var configured = false
    private var position: AVCaptureDevice.Position = .back
    private var _latestJPEG: Data?

    /// The most recent frame (for engines that take a snapshot per turn).
    var latestJPEG: Data? {
        lock.lock(); defer { lock.unlock() }
        return _latestJPEG
    }

    var latestAttachment: Attachment? {
        latestJPEG.map { Attachment(name: "Camera.jpg", mimeType: "image/jpeg", data: $0) }
    }

    func start() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            lastError = "Camera access is off. Enable it in Settings › JARVIS › Camera."
            return false
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let ok = self.configure()
                if ok {
                    self.session.startRunning()
                } else {
                    self.lastError = "No camera is available."
                }
                continuation.resume(returning: ok)
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func flip() {
        queue.async {
            self.position = self.position == .back ? .front : .back
            self.configured = false
            _ = self.configure()
        }
    }

    private func configure() -> Bool {
        if configured { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= 0.5, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now
        var image = CIImage(cvPixelBuffer: pixels).oriented(position == .front ? .leftMirrored : .right)
        let scale = 512 / max(image.extent.width, image.extent.height)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let jpeg = ImageCoder.encode(cgImage, type: .jpeg, quality: 0.6) else { return }
        lock.lock(); _latestJPEG = jpeg; lock.unlock()

        let fingerprint = ImageCoder.fingerprint(cgImage, size: 16)
        let changed = lastFingerprint.map { ImageCoder.difference($0, fingerprint) > 7 } ?? true
        let elapsed = now.timeIntervalSince(lastSent)
        guard elapsed >= 1, changed || elapsed >= 5 else { return }
        lastSent = now
        lastFingerprint = fingerprint
        onFrame?(jpeg)
    }
}

/// Live camera preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
