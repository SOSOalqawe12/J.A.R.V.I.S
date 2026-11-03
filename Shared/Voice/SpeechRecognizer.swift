import Foundation
import Speech
import AVFoundation

/// Live speech-to-text using Apple's Speech framework, with automatic
/// "you stopped talking" detection so voice messages send themselves.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    /// Called with the full text when the user stops talking (auto-send mode).
    var onAutoFinish: ((String) -> Void)?
    /// Called with the text when listening ends without auto-send (to fill the text box).
    var onStopped: ((String) -> Void)?
    /// Send automatically once the user has been quiet for `silenceTimeout`.
    var autoFinishAfterSilence = false
    var silenceTimeout: TimeInterval = 1.4

    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var monitorTimer: Timer?
    private var startedAt = Date()
    private var lastTranscriptChange = Date()
    private var lastVoiceActivity = Date()
    private var generation = 0

    struct LocaleOption: Identifiable, Hashable {
        let id: String
        let name: String
        init(_ id: String, _ name: String) { self.id = id; self.name = name }
    }

    static let localeOptions: [LocaleOption] = [
        LocaleOption("", "System language"),
        LocaleOption("en-US", "English (US)"),
        LocaleOption("en-GB", "English (UK)"),
        LocaleOption("ar-SA", "العربية (Saudi Arabia)"),
        LocaleOption("ar-AE", "العربية (UAE)"),
        LocaleOption("fr-FR", "Français"),
        LocaleOption("es-ES", "Español"),
        LocaleOption("de-DE", "Deutsch"),
        LocaleOption("it-IT", "Italiano"),
        LocaleOption("pt-BR", "Português (Brasil)"),
        LocaleOption("tr-TR", "Türkçe"),
        LocaleOption("hi-IN", "हिन्दी"),
        LocaleOption("ja-JP", "日本語"),
        LocaleOption("zh-CN", "中文 (简体)")
    ]

    func toggle(localeID: String) {
        if isRecording { finish(auto: autoFinishAfterSilence) } else { Task { await start(localeID: localeID) } }
    }

    func start(localeID: String) async {
        guard !isRecording else { return }
        errorMessage = nil
        transcript = ""

        guard await Self.requestPermissions() else {
            errorMessage = "Microphone or speech recognition permission was denied. Enable it in Settings."
            return
        }
        let locale = localeID.isEmpty ? Locale.current : Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            self.request = request

            audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                errorMessage = "No microphone is available."
                return
            }
            let levelHandler: @Sendable (Float) -> Void = { [weak self] level in
                Task { @MainActor in self?.updateLevel(level) }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(request: request, levelHandler: levelHandler))
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            generation += 1
            let current = generation
            let now = Date()
            startedAt = now
            lastTranscriptChange = now
            lastVoiceActivity = now

            let resultHandler: @Sendable (String?, Bool) -> Void = { [weak self] text, done in
                Task { @MainActor in self?.handleResult(text: text, done: done, generation: current) }
            }
            task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(resultHandler))
            monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkForSilence() }
            }
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            stop()
        }
    }

    /// Stops listening without delivering the text anywhere.
    func stop() {
        generation += 1
        monitorTimer?.invalidate()
        monitorTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Stops listening and hands the text to `onAutoFinish` (auto) or `onStopped`.
    func finish(auto: Bool) {
        guard isRecording else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        guard !text.isEmpty else { return }
        if auto { onAutoFinish?(text) } else { onStopped?(text) }
    }

    private func updateLevel(_ value: Float) {
        level = value
        if value > 0.12 { lastVoiceActivity = Date() }
    }

    private func handleResult(text: String?, done: Bool, generation: Int) {
        guard generation == self.generation, isRecording else { return }
        if let text, text != transcript {
            transcript = text
            lastTranscriptChange = Date()
        }
        // The recognizer ended on its own (time limit, long pause, error): deliver what we have.
        if done { finish(auto: autoFinishAfterSilence) }
    }

    /// Ends the turn once the user has been quiet for a moment.
    private func checkForSilence() {
        guard isRecording else { return }
        let now = Date()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if now.timeIntervalSince(startedAt) > 120 {
            finish(auto: autoFinishAfterSilence)
            return
        }
        guard autoFinishAfterSilence else { return }
        if text.isEmpty {
            // Nothing heard at all – give up quietly after a while.
            if now.timeIntervalSince(startedAt) > 15 { stop() }
            return
        }
        let quietFor = now.timeIntervalSince(max(lastTranscriptChange, lastVoiceActivity))
        let wordsStalledFor = now.timeIntervalSince(lastTranscriptChange)
        if quietFor >= silenceTimeout || wordsStalledFor >= 3 {
            finish(auto: true)
        }
    }

    nonisolated private static func makeTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest,
        levelHandler: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            request.append(buffer)
            levelHandler(rms(buffer))
        }
    }

    nonisolated private static func makeResultHandler(
        _ handler: @escaping @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            handler(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
