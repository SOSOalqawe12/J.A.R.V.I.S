import Foundation

/// User preferences, persisted to UserDefaults (API keys go to the Keychain).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: Provider & models

    @Published var provider: ProviderKind { didSet { defaults.set(provider.rawValue, forKey: "provider") } }

    @Published var geminiAPIKey: String { didSet { KeychainStore.set(geminiAPIKey, for: "gemini") } }
    @Published var claudeAPIKey: String { didSet { KeychainStore.set(claudeAPIKey, for: "claude") } }
    @Published var openAIAPIKey: String { didSet { KeychainStore.set(openAIAPIKey, for: "openai") } }
    @Published var localAPIKey: String { didSet { KeychainStore.set(localAPIKey, for: "local") } }
    @Published var deepSeekAPIKey: String { didSet { KeychainStore.set(deepSeekAPIKey, for: "deepseek") } }
    @Published var deepSeekModel: String { didSet { defaults.set(deepSeekModel, forKey: "deepSeekModel") } }

    // MARK: OpenAI & OpenAI-compatible servers

    /// Empty = pick automatically from /models.
    @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }
    @Published var openAIImageModel: String { didSet { defaults.set(openAIImageModel, forKey: "openAIImageModel") } }
    @Published var openAIVoice: String { didSet { defaults.set(openAIVoice, forKey: "openAIVoice") } }
    @Published var localBaseURL: String { didSet { defaults.set(localBaseURL, forKey: "localBaseURL") } }
    @Published var localModel: String { didSet { defaults.set(localModel, forKey: "localModel") } }
    /// native = OpenAI tool calling, prompted = <tool_call> tags in text, off = chat only.
    @Published var localToolMode: String { didSet { defaults.set(localToolMode, forKey: "localToolMode") } }

    /// Empty string = pick automatically from the models available to the key.
    @Published var geminiChatModel: String { didSet { defaults.set(geminiChatModel, forKey: "geminiChatModel") } }
    @Published var geminiImageModel: String { didSet { defaults.set(geminiImageModel, forKey: "geminiImageModel") } }
    @Published var geminiTTSModel: String { didSet { defaults.set(geminiTTSModel, forKey: "geminiTTSModel") } }
    @Published var geminiVoiceName: String { didSet { defaults.set(geminiVoiceName, forKey: "geminiVoiceName") } }

    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    /// low / medium / high / xhigh / max
    @Published var claudeEffort: String { didSet { defaults.set(claudeEffort, forKey: "claudeEffort") } }
    /// Server-side refusal fallback on models that support it.
    @Published var claudeRefusalFallback: Bool { didSet { defaults.set(claudeRefusalFallback, forKey: "claudeRefusalFallback") } }

    // MARK: Claude Code (subscription) – macOS

    @Published var claudeCodePath: String { didSet { defaults.set(claudeCodePath, forKey: "claudeCodePath") } }
    @Published var claudeCodeModel: String { didSet { defaults.set(claudeCodeModel, forKey: "claudeCodeModel") } }
    @Published var claudeCodeAllowBash: Bool { didSet { defaults.set(claudeCodeAllowBash, forKey: "claudeCodeAllowBash") } }

    // MARK: Personality

    @Published var userName: String { didSet { defaults.set(userName, forKey: "userName") } }
    @Published var customInstructions: String { didSet { defaults.set(customInstructions, forKey: "customInstructions") } }

    // MARK: Voice

    @Published var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    @Published var handsFree: Bool { didSet { defaults.set(handsFree, forKey: "handsFree") } }
    @Published var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    /// Empty = system language.
    @Published var recognitionLocale: String { didSet { defaults.set(recognitionLocale, forKey: "recognitionLocale") } }
    /// Send voice messages automatically when the user stops talking.
    @Published var autoSendVoice: Bool { didSet { defaults.set(autoSendVoice, forKey: "autoSendVoice") } }
    /// "natural" = Gemini neural voice, "device" = on-device speech synthesis.
    @Published var voiceEngine: String { didSet { defaults.set(voiceEngine, forKey: "voiceEngine") } }
    /// Real-time Gemini Live conversation in voice mode.
    @Published var liveVoiceEnabled: Bool { didSet { defaults.set(liveVoiceEnabled, forKey: "liveVoiceEnabled") } }
    /// Empty = pick the newest Live model automatically.
    @Published var geminiLiveModel: String { didSet { defaults.set(geminiLiveModel, forKey: "geminiLiveModel") } }
    /// auto / gemini / openai / classic
    @Published var liveEngine: String { didSet { defaults.set(liveEngine, forKey: "liveEngine") } }
    @Published var openAIRealtimeModel: String { didSet { defaults.set(openAIRealtimeModel, forKey: "openAIRealtimeModel") } }
    @Published var openAIRealtimeVoice: String { didSet { defaults.set(openAIRealtimeVoice, forKey: "openAIRealtimeVoice") } }
    /// Brain to switch to when the main one is rate-limited ("" = none).
    @Published var fallbackProvider: String { didSet { defaults.set(fallbackProvider, forKey: "fallbackProvider") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    /// Listen for "Hey JARVIS" while the app is open.
    @Published var wakeWordEnabled: Bool { didSet { defaults.set(wakeWordEnabled, forKey: "wakeWordEnabled") } }

    // MARK: Agent behaviour

    @Published var maxAgentSteps: Int { didSet { defaults.set(maxAgentSteps, forKey: "maxAgentSteps") } }
    /// macOS: run shell/AppleScript actions without asking first.
    @Published var autoApproveActions: Bool { didSet { defaults.set(autoApproveActions, forKey: "autoApproveActions") } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    @Published var memoryEnabled: Bool { didSet { defaults.set(memoryEnabled, forKey: "memoryEnabled") } }
    @Published var streamResponses: Bool { didSet { defaults.set(streamResponses, forKey: "streamResponses") } }

    // MARK: iOS

    @Published var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: "appLockEnabled") } }

    // MARK: macOS screen watch

    @Published var watchInterval: Double { didSet { defaults.set(watchInterval, forKey: "watchInterval") } }
    @Published var watchNotifications: Bool { didSet { defaults.set(watchNotifications, forKey: "watchNotifications") } }
    @Published var watchSpeakSuggestions: Bool { didSet { defaults.set(watchSpeakSuggestions, forKey: "watchSpeakSuggestions") } }
    @Published var watchFocus: String { didSet { defaults.set(watchFocus, forKey: "watchFocus") } }
    /// Comma separated app names that are never captured.
    @Published var privacyBlocklist: String { didSet { defaults.set(privacyBlocklist, forKey: "privacyBlocklist") } }
    @Published var workspacePath: String { didSet { defaults.set(workspacePath, forKey: "workspacePath") } }

    private init() {
        let d = UserDefaults.standard
        provider = ProviderKind(rawValue: d.string(forKey: "provider") ?? "") ?? .gemini
        geminiAPIKey = KeychainStore.get("gemini")
        claudeAPIKey = KeychainStore.get("claude")
        openAIAPIKey = KeychainStore.get("openai")
        localAPIKey = KeychainStore.get("local")
        deepSeekAPIKey = KeychainStore.get("deepseek")
        deepSeekModel = d.string(forKey: "deepSeekModel") ?? "deepseek-chat"
        openAIModel = d.string(forKey: "openAIModel") ?? ""
        openAIImageModel = d.string(forKey: "openAIImageModel") ?? "gpt-image-1"
        openAIVoice = d.string(forKey: "openAIVoice") ?? "onyx"
        localBaseURL = d.string(forKey: "localBaseURL") ?? "http://localhost:11434/v1"
        localModel = d.string(forKey: "localModel") ?? ""
        localToolMode = d.string(forKey: "localToolMode") ?? "native"
        geminiChatModel = d.string(forKey: "geminiChatModel") ?? ""
        geminiImageModel = d.string(forKey: "geminiImageModel") ?? ""
        geminiTTSModel = d.string(forKey: "geminiTTSModel") ?? ""
        geminiVoiceName = d.string(forKey: "geminiVoiceName") ?? "Charon"
        claudeModel = d.string(forKey: "claudeModel") ?? ClaudeClient.defaultModel
        claudeEffort = d.string(forKey: "claudeEffort") ?? "medium"
        claudeRefusalFallback = d.object(forKey: "claudeRefusalFallback") as? Bool ?? true
        claudeCodePath = d.string(forKey: "claudeCodePath") ?? ""
        claudeCodeModel = d.string(forKey: "claudeCodeModel") ?? ""
        claudeCodeAllowBash = d.object(forKey: "claudeCodeAllowBash") as? Bool ?? false
        userName = d.string(forKey: "userName") ?? ""
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? false
        handsFree = d.object(forKey: "handsFree") as? Bool ?? false
        voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.5
        recognitionLocale = d.string(forKey: "recognitionLocale") ?? ""
        autoSendVoice = d.object(forKey: "autoSendVoice") as? Bool ?? true
        voiceEngine = d.string(forKey: "voiceEngine") ?? "natural"
        liveVoiceEnabled = d.object(forKey: "liveVoiceEnabled") as? Bool ?? true
        geminiLiveModel = d.string(forKey: "geminiLiveModel") ?? ""
        wakeWordEnabled = d.object(forKey: "wakeWordEnabled") as? Bool ?? false
        liveEngine = d.string(forKey: "liveEngine") ?? "auto"
        openAIRealtimeModel = d.string(forKey: "openAIRealtimeModel") ?? "gpt-realtime"
        openAIRealtimeVoice = d.string(forKey: "openAIRealtimeVoice") ?? "cedar"
        fallbackProvider = d.string(forKey: "fallbackProvider") ?? ""
        onboardingDone = d.object(forKey: "onboardingDone") as? Bool ?? false
        memoryEnabled = d.object(forKey: "memoryEnabled") as? Bool ?? true
        streamResponses = d.object(forKey: "streamResponses") as? Bool ?? true
        maxAgentSteps = d.object(forKey: "maxAgentSteps") as? Int ?? 15
        autoApproveActions = d.object(forKey: "autoApproveActions") as? Bool ?? false
        hapticsEnabled = d.object(forKey: "hapticsEnabled") as? Bool ?? true
        appLockEnabled = d.object(forKey: "appLockEnabled") as? Bool ?? false
        watchInterval = d.object(forKey: "watchInterval") as? Double ?? 90
        watchNotifications = d.object(forKey: "watchNotifications") as? Bool ?? true
        watchSpeakSuggestions = d.object(forKey: "watchSpeakSuggestions") as? Bool ?? false
        watchFocus = d.string(forKey: "watchFocus") ?? ""
        privacyBlocklist = d.string(forKey: "privacyBlocklist") ?? "1Password, Keychain Access, Bitwarden, Passwords"
        workspacePath = d.string(forKey: "workspacePath") ?? ""
    }

    var hasGeminiKey: Bool { !geminiAPIKey.isEmpty }
    var hasClaudeKey: Bool { !claudeAPIKey.isEmpty }
    var hasOpenAIKey: Bool { !openAIAPIKey.isEmpty }
    var hasDeepSeekKey: Bool { !deepSeekAPIKey.isEmpty }

    /// True when the selected provider has what it needs to run.
    var isProviderConfigured: Bool { isConfigured(provider) }

    func isConfigured(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .gemini: return hasGeminiKey
        case .claude: return hasClaudeKey
        case .claudeCode: return true
        case .openai: return hasOpenAIKey
        case .local: return !localBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .apple: return AppleIntelligence.isAvailable
        case .deepseek: return hasDeepSeekKey
        }
    }

    var blockedApps: [String] {
        privacyBlocklist
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
