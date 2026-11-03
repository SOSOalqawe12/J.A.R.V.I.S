import Foundation
import AVFoundation
import CoreImage
import SwiftUI

/// A real-time, interruptible voice conversation over the Gemini Live API.
/// JARVIS hears you continuously, answers with a natural voice, can be
/// interrupted mid-sentence, uses all its tools while talking, and can see
/// through the camera.
@MainActor
final class LiveVoiceSession: ObservableObject {
    struct Line: Identifiable, Hashable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    enum Phase: Equatable {
        case idle, connecting, listening, speaking, working(String), ended, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [Line] = []
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var createdFiles: [String] = []
    @Published private(set) var cameraOn = false
    @Published private(set) var modelName = ""
    @Published var micMuted = false {
        didSet { audio.muted = micMuted }
    }

    let camera = CameraFrameSource()
    private let audio = LiveAudioIO()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var tools: [String: AgentTool] = [:]
    private var openUserLine: Int?
    private var openModelLine: Int?
    private var initialText: String?
    private let settings = AppSettings.shared

    static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    var isActive: Bool {
        switch phase {
        case .connecting, .listening, .speaking, .working: return true
        default: return false
        }
    }

    // MARK: Lifecycle

    func start(initialText: String? = nil) async {
        guard !isActive else { return }
        guard settings.hasGeminiKey else {
            phase = .failed("Live voice needs a Gemini API key.")
            return
        }
        phase = .connecting
        lines = []
        createdFiles = []
        openUserLine = nil
        openModelLine = nil
        self.initialText = initialText

        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings › JARVIS.")
            return
        }

        let key = settings.geminiAPIKey
        let model: String
        if settings.geminiLiveModel.isEmpty {
            let models = await GeminiModelCatalog.shared.models(apiKey: key)
            model = GeminiModelPicker.best(models, for: .live) ?? GeminiModelPicker.fallbackLive
        } else {
            model = settings.geminiLiveModel
        }
        modelName = model

        let allTools = Toolbox.sharedTools() + iOSTools.all
        tools = allTools.reduce(into: [:]) { $0[$1.name] = $1 }

        var components = URLComponents(string: LiveVoiceSession.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { phase = .failed("Bad Live API URL."); return }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 32 * 1024 * 1024
        self.socket = socket
        socket.resume()

        do {
            try await send(setupMessage(model: model, tools: allTools))
        } catch {
            fail("Couldn't connect: \(error.localizedDescription)")
            return
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func stop() {
        guard phase != .ended else { return }
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio.stop()
        if cameraOn { toggleCamera() }
        let wasActive = isActive
        phase = .ended
        if wasActive { saveTranscript() }
    }

    private func fail(_ message: String) {
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        audio.stop()
        if cameraOn { toggleCamera() }
        saveTranscript()
        phase = .failed(message)
    }

    // MARK: Outgoing

    private func setupMessage(model: String, tools: [AgentTool]) -> JSONValue {
        let system = SystemPrompts.make(settings: settings) + """


        # Live voice conversation
        You are speaking out loud in a real-time conversation. Keep replies short, warm and natural – usually one to \
        three sentences – unless the user asks for detail. Never read out markdown, code, file contents or long URLs. \
        Before using a tool, say a few words about what you're doing ("One moment, creating that file"). \
        If the camera is on you receive frames of what the user is looking at.
        """
        let declarations = tools.map { GeminiProvider.declaration($0.spec) }
        let setup: JSONValue = [
            "model": .string("models/" + model),
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(settings.geminiVoiceName)]]]
            ],
            "systemInstruction": ["parts": [["text": .string(system)]]],
            "tools": [["functionDeclarations": .array(declarations)]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            "contextWindowCompression": ["slidingWindow": [:]]
        ]
        return ["setup": setup]
    }

    private func send(_ message: JSONValue) async throws {
        guard let socket else { return }
        try await socket.send(.string(message.jsonString()))
    }

    private func sendAudio(_ pcm: Data) {
        guard isActive else { return }
        let message: JSONValue = ["realtimeInput": ["audio": ["data": .string(pcm.base64EncodedString()), "mimeType": "audio/pcm;rate=16000"]]]
        Task { try? await send(message) }
    }

    private func sendFrame(_ jpeg: Data) {
        guard isActive, cameraOn else { return }
        let message: JSONValue = ["realtimeInput": ["video": ["data": .string(jpeg.base64EncodedString()), "mimeType": "image/jpeg"]]]
        Task { try? await send(message) }
    }

    func sendText(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isActive else { return }
        lines.append(Line(isUser: true, text: clean))
        openUserLine = nil
        let message: JSONValue = ["clientContent": ["turns": [["role": "user", "parts": [["text": .string(clean)]]]], "turnComplete": true]]
        Task { try? await send(message) }
    }

    func toggleCamera() {
        if cameraOn {
            camera.stop()
            cameraOn = false
        } else {
            Task {
                camera.onFrame = { @Sendable [weak self] jpeg in
                    Task { @MainActor in self?.sendFrame(jpeg) }
                }
                if await camera.start() {
                    cameraOn = true
                }
            }
        }
    }

    func flipCamera() { camera.flip() }

    // MARK: Incoming

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let json = try? JSONValue.parse(data) else { continue }
                await handle(json)
            } catch {
                guard !Task.isCancelled, phase != .ended else { return }
                let reason = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                fail(reason.map { "Live session closed: \($0)" } ?? "Live session ended: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(_ json: JSONValue) async {
        if json["setupComplete"] != nil {
            beginAudio()
            return
        }
        if let content = json["serverContent"] {
            if content["interrupted"]?.boolValue == true {
                audio.flushPlayback()
                closeLines()
                phase = .listening
            }
            if let text = content["inputTranscription"]?["text"]?.stringValue, !text.isEmpty {
                appendUser(text)
            }
            if let text = content["outputTranscription"]?["text"]?.stringValue, !text.isEmpty {
                appendModel(text)
            }
            for part in content["modelTurn"]?["parts"]?.arrayValue ?? [] {
                if let inline = part["inlineData"], let b64 = inline["data"]?.stringValue, let pcm = Data(base64Encoded: b64) {
                    audio.play(pcm16: pcm)
                    if case .working = phase {} else { phase = .speaking }
                }
            }
            if content["turnComplete"]?.boolValue == true {
                closeLines()
                if !audio.isPlaying { phase = .listening }
            }
        }
        if let call = json["toolCall"] {
            await runTools(call["functionCalls"]?.arrayValue ?? [])
        }
        if json["goAway"] != nil {
            lines.append(Line(isUser: false, text: "(The live session is about to end – start a new one to keep talking.)"))
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
            try audio.start()
            audio.muted = micMuted
            phase = .listening
            Haptics.success()
            if let initialText, !initialText.isEmpty {
                self.initialText = nil
                sendText(initialText)
            }
        } catch {
            fail("Audio couldn't start: \(error.localizedDescription)")
        }
    }

    private func runTools(_ calls: [JSONValue]) async {
        let context = ToolContext(workspace: .shared, settings: settings, approvals: ApprovalCenter.shared)
        var responses: [JSONValue] = []
        for call in calls {
            let id = call["id"]?.stringValue ?? ""
            let name = call["name"]?.stringValue ?? ""
            let arguments = call["args"] ?? [:]
            let tool = tools[name]
            phase = .working(tool?.activityLabel ?? name)
            var response: [String: JSONValue]
            if let tool {
                do {
                    let output = try await tool.run(arguments, context: context)
                    response = ["result": .string(output.text)]
                    if !output.files.isEmpty {
                        createdFiles.insert(contentsOf: output.files, at: 0)
                        ChatViewModel.shared.noteCreatedFiles(output.files)
                    }
                } catch {
                    response = ["error": .string(error.localizedDescription)]
                }
            } else {
                response = ["error": .string("Unknown tool \(name)")]
            }
            var entry: [String: JSONValue] = ["name": .string(name), "response": .object(response)]
            if !id.isEmpty { entry["id"] = .string(id) }
            responses.append(.object(entry))
        }
        try? await send(["toolResponse": ["functionResponses": .array(responses)]])
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

/// Camera frames (≈1 per second, JPEG) for live vision.
final class CameraFrameSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFrame: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "jarvis.camera")
    private let context = CIContext()
    private var lastFrame = Date.distantPast
    private var configured = false
    private var position: AVCaptureDevice.Position = .back

    func start() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                let ok = self.configure()
                if ok { self.session.startRunning() }
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
        session.sessionPreset = .high
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
        guard now.timeIntervalSince(lastFrame) >= 1, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        var image = CIImage(cvPixelBuffer: pixels).oriented(position == .front ? .leftMirrored : .right)
        let scale = 768 / max(image.extent.width, image.extent.height)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let jpeg = ImageCoder.encode(cgImage, type: .jpeg, quality: 0.6) else { return }
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
