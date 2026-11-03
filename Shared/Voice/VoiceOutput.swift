import Foundation
import AVFoundation
import NaturalLanguage

/// Speaks JARVIS's replies, using Gemini's natural neural voices when available
/// and falling back to the best installed device voice.
@MainActor
final class VoiceOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceOutput()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var level: Float = 0
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var prepareTask: Task<Void, Never>?
    private var meterTimer: Timer?
    private var cache: [String: Data] = [:]

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var usesNaturalVoice: Bool {
        let settings = AppSettings.shared
        return settings.voiceEngine == "natural" && (settings.hasGeminiKey || settings.hasOpenAIKey)
    }

    func speak(_ text: String) {
        let clean = VoiceOutput.speakable(text)
        guard !clean.isEmpty else { onFinish?(); return }
        stop()
        activateSession()
        if usesNaturalVoice {
            speakNatural(clean)
        } else {
            speakWithDevice(clean)
        }
    }

    func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        player?.stop()
        player = nil
        meterTimer?.invalidate()
        meterTimer = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isPreparing = false
        level = 0
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    // MARK: Natural (Gemini) voice

    private func speakNatural(_ text: String) {
        let settings = AppSettings.shared
        let snippet = String(text.prefix(1800))
        let cacheKey = settings.geminiVoiceName + "|" + snippet
        isSpeaking = true
        isPreparing = true
        if let cached = cache[cacheKey] {
            play(cached, fallbackText: snippet)
            return
        }
        let key = settings.geminiAPIKey
        let voice = settings.geminiVoiceName
        let preferredModel = settings.geminiTTSModel
        let openAIKey = settings.openAIAPIKey
        let openAIVoice = settings.openAIVoice
        prepareTask = Task { [weak self] in
            do {
                let wav: Data
                if key.isEmpty {
                    wav = try await OpenAICompatibleClient(baseURL: OpenAICompatibleClient.openAIBaseURL, apiKey: openAIKey)
                        .speech(snippet, voice: openAIVoice)
                } else {
                    let model = await GeminiModelCatalog.shared.resolve(.tts, preferred: preferredModel, apiKey: key)
                    wav = try await GeminiClient(apiKey: key).synthesizeSpeech(text: snippet, voice: voice, style: nil, model: model)
                }
                guard !Task.isCancelled, let self else { return }
                if self.cache.count > 20 { self.cache.removeAll() }
                self.cache[cacheKey] = wav
                self.play(wav, fallbackText: snippet)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.speakWithDevice(snippet)
            }
        }
    }

    private func play(_ wav: Data, fallbackText: String) {
        isPreparing = false
        do {
            let player = try AVAudioPlayer(data: wav)
            player.delegate = self
            player.isMeteringEnabled = true
            player.prepareToPlay()
            self.player = player
            isSpeaking = true
            player.play()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    player.updateMeters()
                    let power = player.averagePower(forChannel: 0)
                    self.level = max(0, min(1, (power + 50) / 50))
                }
            }
        } catch {
            speakWithDevice(fallbackText)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        meterTimer?.invalidate()
        meterTimer = nil
        player = nil
        isSpeaking = false
        isPreparing = false
        level = 0
        onFinish?()
    }

    // MARK: Device voice

    private func speakWithDevice(_ text: String) {
        isPreparing = false
        let settings = AppSettings.shared
        let utterance = AVSpeechUtterance(string: text)
        let preferred = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier)
        let language = VoiceOutput.language(of: text)
        if let preferred, language == nil || preferred.language.hasPrefix(language ?? "") {
            utterance.voice = preferred
        } else {
            utterance.voice = VoiceOutput.bestVoice(for: text)
        }
        utterance.rate = Float(settings.speechRate) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) + AVSpeechUtteranceMinimumSpeechRate
        utterance.pitchMultiplier = 0.95
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.level = 0
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.level = Float.random(in: 0.35...0.8) }
    }

    // MARK: Helpers

    /// Strips Markdown/code so it reads naturally.
    nonisolated static func speakable(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "(?s)```.*?```", with: " (code omitted) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "a link", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }

    nonisolated static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Prefers premium/enhanced voices, British English for the classic JARVIS sound.
    nonisolated static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let language = language(of: text) ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            var score = 0
            switch voice.quality {
            case .premium: score += 30
            case .enhanced: score += 20
            default: break
            }
            if language == "en" && voice.language == "en-GB" { score += 10 }
            if voice.name.contains("Daniel") || voice.name.contains("Arthur") { score += 5 }
            return score
        }
        return voices.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: language == "en" ? "en-GB" : language)
    }

    nonisolated static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("ar") }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
}
