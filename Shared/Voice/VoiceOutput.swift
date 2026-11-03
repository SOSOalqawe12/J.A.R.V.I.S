import Foundation
import AVFoundation
import NaturalLanguage

/// Speaks JARVIS's replies with the best installed voice for the reply's language.
@MainActor
final class VoiceOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceOutput()

    @Published private(set) var isSpeaking = false
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let clean = VoiceOutput.speakable(text)
        guard !clean.isEmpty else { onFinish?(); return }
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let settings = AppSettings.shared
        let utterance = AVSpeechUtterance(string: clean)
        let preferred = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier)
        let language = VoiceOutput.language(of: clean)
        if let preferred, language == nil || preferred.language.hasPrefix(language ?? "") {
            utterance.voice = preferred
        } else {
            utterance.voice = VoiceOutput.bestVoice(for: clean)
        }
        utterance.rate = Float(settings.speechRate) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) + AVSpeechUtteranceMinimumSpeechRate
        utterance.pitchMultiplier = 0.95
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

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
