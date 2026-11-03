import Foundation
import Speech
import AVFoundation

/// Live speech-to-text using Apple's Speech framework.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    /// Called when the user stops talking (hands-free / auto-send mode).
    var onAutoFinish: ((String) -> Void)?
    var autoFinishAfterSilence = false

    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?

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
        if isRecording { stop() } else { Task { await start(localeID: localeID) } }
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
            self.request = request

            audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let levelHandler: @Sendable (Float) -> Void = { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(request: request, levelHandler: levelHandler))
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            let resultHandler: @Sendable (String?, Bool) -> Void = { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text {
                        self.transcript = text
                        self.scheduleSilenceCheck()
                    }
                    if done, self.isRecording { self.stop() }
                }
            }
            task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(resultHandler))
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
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

    private func scheduleSilenceCheck() {
        guard autoFinishAfterSilence else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let text = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.stop()
                if !text.isEmpty { self.onAutoFinish?(text) }
            }
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
