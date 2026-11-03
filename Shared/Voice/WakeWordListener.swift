import Foundation
import Speech
import AVFoundation
#if os(iOS)
import AudioToolbox
#endif

/// Listens for "Hey JARVIS" while the app is open (on-device recognition when
/// available) and hands any words after the wake word to `onWake`.
@MainActor
final class WakeWordListener: ObservableObject {
    static let shared = WakeWordListener()

    @Published private(set) var isListening = false
    var onWake: ((String) -> Void)?

    private var enabled = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var generation = 0

    nonisolated static let wakeWords = ["jarvis", "jervis", "javis", "jarvas", "جارفيس", "جارڤيس", "جارفس"]

    func setEnabled(_ on: Bool) {
        if on {
            enabled = true
            Task { await begin() }
        } else {
            enabled = false
            teardown()
        }
    }

    /// Temporarily releases the microphone (another feature needs it).
    func pause() { teardown() }

    func resumeIfEnabled() {
        guard enabled, !isListening else { return }
        Task { await begin() }
    }

    nonisolated static func detect(in transcript: String) -> String? {
        let lower = transcript.lowercased()
        for word in wakeWords {
            if let range = lower.range(of: word, options: .backwards) {
                let after = transcript[range.upperBound...]
                return after.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            }
        }
        return nil
    }

    private func begin() async {
        guard enabled, !isListening else { return }
        guard await SpeechRecognizer.requestPermissions() else { enabled = false; return }
        guard enabled, !isListening else { return }
        let localeID = AppSettings.shared.recognitionLocale
        let locale = localeID.isEmpty ? Locale.current : Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else { return }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            request.contextualStrings = ["JARVIS", "Hey JARVIS"]
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: WakeWordListener.tapBlock(request))
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            isListening = true
            generation += 1
            let current = generation
            let handler: @Sendable (String?, Bool) -> Void = { [weak self] text, done in
                Task { @MainActor in self?.handle(text: text, done: done, generation: current) }
            }
            task = recognizer.recognitionTask(with: request, resultHandler: WakeWordListener.resultBlock(handler))
            // Recognition sessions are capped in length; recycle regularly.
            restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.recycle() }
            }
        } catch {
            teardown()
        }
    }

    private func handle(text: String?, done: Bool, generation: Int) {
        guard generation == self.generation, isListening else { return }
        if let text, let command = WakeWordListener.detect(in: text) {
            teardown()
            #if os(iOS)
            AudioServicesPlaySystemSound(1113)
            #endif
            onWake?(command)
            return
        }
        if done { recycle() }
    }

    private func recycle() {
        teardown()
        guard enabled else { return }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await begin()
        }
    }

    private func teardown() {
        restartTimer?.invalidate()
        restartTimer = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        isListening = false
        generation += 1
    }

    nonisolated private static func tapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultBlock(_ handler: @escaping @Sendable (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            handler(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }
}
