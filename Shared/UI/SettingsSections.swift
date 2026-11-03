import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// AI provider, keys and models.
struct AIProviderSettingsSections: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var geminiModels: [GeminiModelInfo] = []
    @State private var claudeModels: [ClaudeClient.ModelInfo] = []
    @State private var testing = false
    @State private var testResult: String?
    @State private var openAIModels: [String] = []
    @State private var localModels: [String] = []
    @State private var detected: [LocalServerDetector.Found] = []
    @State private var localStatus: String?
    @State private var detecting = false

    var body: some View {
        Group {
            Section {
                Picker("Brain", selection: $settings.provider) {
                    ForEach(ProviderKind.available) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } header: {
                Text("AI provider")
            } footer: {
                Text(providerFooter)
            }

            Section {
                HStack {
                    SecureField("Gemini API key", text: $settings.geminiAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    pasteButton { settings.geminiAPIKey = $0 }
                }
                Link("Get a free key at Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                if settings.hasGeminiKey {
                    modelPicker("Chat model", selection: $settings.geminiChatModel, options: GeminiModelPicker.candidates(geminiModels, for: .chat).map(\.id))
                    modelPicker("Image model", selection: $settings.geminiImageModel, options: GeminiModelPicker.candidates(geminiModels, for: .image).map(\.id))
                    modelPicker("Speech model", selection: $settings.geminiTTSModel, options: GeminiModelPicker.candidates(geminiModels, for: .tts).map(\.id))
                    modelPicker("Live voice model", selection: $settings.geminiLiveModel, options: GeminiModelPicker.candidates(geminiModels, for: .live).map(\.id))
                    Picker("Audio file voice", selection: $settings.geminiVoiceName) {
                        ForEach(AIProviderSettingsSections.geminiVoices, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Refresh model list") { Task { await loadGeminiModels(refresh: true) } }
                }
            } header: {
                Text("Google Gemini")
            } footer: {
                Text("Gemini powers chat, image generation & editing, spoken audio files and web search. \"Automatic\" picks the newest model your key can use.")
            }

            Section {
                HStack {
                    SecureField("Claude API key", text: $settings.claudeAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    pasteButton { settings.claudeAPIKey = $0 }
                }
                Link("Create a key in the Claude Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                if settings.hasClaudeKey {
                    Picker("Model", selection: $settings.claudeModel) {
                        ForEach(claudeModelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Effort", selection: $settings.claudeEffort) {
                        ForEach(ClaudeClient.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Toggle("Retry declined requests on a fallback model", isOn: $settings.claudeRefusalFallback)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Higher effort = smarter but slower and more tokens. Image generation still uses Gemini if a Gemini key is set.")
            }

            openAISection
            localSection

            Section {
                Text(AppleIntelligence.status)
                    .font(.callout)
                    .foregroundColor(AppleIntelligence.isAvailable ? .primary : .secondary)
            } header: {
                Text("On-device (Apple Intelligence)")
            } footer: {
                Text("Free, private and offline. Uses Apple's small on-device model with a focused set of tools – great for quick notes, timers, reminders and simple questions.")
            }

            Section {
                Picker("When rate-limited, switch to", selection: $settings.fallbackProvider) {
                    Text("Don't switch").tag("")
                    ForEach(ProviderKind.available.filter { $0 != settings.provider }) { kind in
                        Text(kind.shortName + (settings.isConfigured(kind) ? "" : " (not set up)")).tag(kind.rawValue)
                    }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Free tiers have tight limits. JARVIS waits and retries when asked, Gemini drops to its higher-limit Lite model, and then this backup brain takes over (e.g. a local Ollama model is unlimited).")
            }

            Section {
                Toggle("Stream replies as they're written", isOn: $settings.streamResponses)
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text(testing ? "Testing…" : "Test connection")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || !settings.isProviderConfigured)
                if let testResult {
                    Text(testResult).font(.footnote).foregroundColor(.secondary).textSelection(.enabled)
                }
            }
        }
        .task(id: settings.geminiAPIKey) { await loadGeminiModels(refresh: false) }
        .task(id: settings.claudeAPIKey) { await loadClaudeModels() }
        .task(id: settings.openAIAPIKey) { await loadOpenAIModels() }
    }

    // MARK: OpenAI

    private var openAISection: some View {
        Section {
            HStack {
                SecureField("OpenAI API key", text: $settings.openAIAPIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                pasteButton { settings.openAIAPIKey = $0 }
            }
            Link("Create a key at platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
            if settings.hasOpenAIKey {
                Picker("Chat model", selection: $settings.openAIModel) {
                    Text("Automatic").tag("")
                    ForEach(openAIModels, id: \.self) { Text($0).tag($0) }
                    if !settings.openAIModel.isEmpty && !openAIModels.contains(settings.openAIModel) {
                        Text(settings.openAIModel).tag(settings.openAIModel)
                    }
                }
                TextField("Image model", text: $settings.openAIImageModel)
                    .autocorrectionDisabled()
                Picker("Voice", selection: $settings.openAIVoice) {
                    ForEach(OpenAICompatibleClient.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        } header: {
            Text("OpenAI")
        } footer: {
            Text("Choose “OpenAI” as the brain to chat with GPT models. The key is also used for images and spoken audio when no Gemini key is set.")
        }
    }

    // MARK: Local & custom servers

    private var localSection: some View {
        Section {
            TextField("Server URL, e.g. http://localhost:11434/v1", text: $settings.localBaseURL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Menu("Presets: Ollama, LM Studio, OpenRouter, Groq…") {
                ForEach(OpenAICompatibleClient.presets) { preset in
                    Button("\(preset.name) – \(preset.baseURL)") {
                        settings.localBaseURL = preset.baseURL
                        settings.localModel = ""
                        localStatus = preset.note
                        localModels = []
                    }
                }
            }
            SecureField("API key (only if the server needs one)", text: $settings.localAPIKey)
                .textContentType(.password)
                .autocorrectionDisabled()
            Picker("Model", selection: $settings.localModel) {
                Text("First available").tag("")
                ForEach(localModels, id: \.self) { Text($0).tag($0) }
                if !settings.localModel.isEmpty && !localModels.contains(settings.localModel) {
                    Text(settings.localModel).tag(settings.localModel)
                }
            }
            Picker("Tool use", selection: $settings.localToolMode) {
                Text("Native function calling").tag("native")
                Text("Prompted (<tool_call> tags)").tag("prompted")
                Text("Off – chat only").tag("off")
            }
            HStack {
                Button("Load models") { Task { await loadLocalModels() } }
                Spacer()
                Button(detecting ? "Scanning…" : "Detect servers") { Task { await detectServers() } }
                    .disabled(detecting)
            }
            .buttonStyle(.borderless)
            ForEach(detected) { server in
                Button {
                    settings.localBaseURL = server.baseURL
                    localModels = server.models
                    if settings.localModel.isEmpty || !server.models.contains(settings.localModel) {
                        settings.localModel = server.models.first ?? ""
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(server.name) · \(server.baseURL)").font(.callout)
                        Text("\(server.models.count) model(s): \(server.models.prefix(4).joined(separator: ", "))")
                            .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }
            }
            if let localStatus {
                Text(localStatus).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("Local & custom models")
        } footer: {
            #if os(iOS)
            Text("Run Ollama or LM Studio on your computer and enter its network address (e.g. http://192.168.1.20:11434/v1 – for Ollama start it with OLLAMA_HOST=0.0.0.0). Also works with any OpenAI-compatible cloud (OpenRouter, Groq, DeepSeek…). Then choose “Local” as the brain.")
            #else
            Text("Works with Ollama, LM Studio, llama.cpp, Jan, vLLM and any OpenAI-compatible cloud (OpenRouter, Groq, DeepSeek, Mistral, xAI…). Pick a model with tool support (e.g. Qwen, Llama 3.1+, Mistral) for file making, or switch Tool use to Prompted.")
            #endif
        }
    }

    private func loadOpenAIModels() async {
        guard settings.hasOpenAIKey else { openAIModels = []; return }
        let client = OpenAICompatibleClient(baseURL: OpenAICompatibleClient.openAIBaseURL, apiKey: settings.openAIAPIKey)
        let all = (try? await client.listModels()) ?? []
        openAIModels = all.filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o") }
            .filter { id in !["audio", "realtime", "transcribe", "tts", "image", "embedding", "moderation"].contains { id.contains($0) } }
    }

    private func loadLocalModels() async {
        let client = OpenAICompatibleClient(baseURL: settings.localBaseURL, apiKey: settings.localAPIKey)
        do {
            localModels = try await client.listModels()
            localStatus = "✅ Connected – \(localModels.count) model(s)."
            if settings.localModel.isEmpty, let first = localModels.first { settings.localModel = first }
        } catch {
            localStatus = "❌ \(error.localizedDescription)"
        }
    }

    private func detectServers() async {
        detecting = true
        defer { detecting = false }
        var hosts = ["localhost", "127.0.0.1"]
        if let host = LocalServerDetector.host(of: settings.localBaseURL) { hosts.append(host) }
        detected = await LocalServerDetector.scan(hosts: hosts)
        localStatus = detected.isEmpty ? "No servers found on \(hosts.joined(separator: ", ")). Start Ollama/LM Studio, or type its address." : nil
    }

    static let geminiVoices = ["Charon", "Kore", "Puck", "Zephyr", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
                               "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
                               "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
                               "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"]

    private var providerFooter: String {
        switch settings.provider {
        case .gemini: return "Gemini is the default brain on iPhone and can generate images and audio."
        case .claude: return "Claude via your Anthropic API key."
        case .claudeCode: return "Uses your Claude Pro/Max subscription through the official Claude Code CLI (install it and run `claude` once to log in)."
        case .openai: return "OpenAI GPT models via your API key."
        case .local: return "Your own model server – Ollama, LM Studio, llama.cpp – or any OpenAI-compatible service."
        case .apple: return "Apple's on-device model: private and offline (iOS 26 / macOS 26 with Apple Intelligence)."
        }
    }

    private var claudeModelOptions: [String] {
        var options = ClaudeClient.suggestedModels
        for model in claudeModels where !options.contains(model.id) { options.append(model.id) }
        if !options.contains(settings.claudeModel) { options.insert(settings.claudeModel, at: 0) }
        return options
    }

    private func modelPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(options.sorted().reversed(), id: \.self) { Text($0).tag($0) }
            if !selection.wrappedValue.isEmpty && !options.contains(selection.wrappedValue) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }

    private func pasteButton(_ apply: @escaping (String) -> Void) -> some View {
        Button {
            #if os(iOS)
            if let text = UIPasteboard.general.string { apply(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            #else
            if let text = NSPasteboard.general.string(forType: .string) { apply(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            #endif
        } label: {
            Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
        .help("Paste")
    }

    private func loadGeminiModels(refresh: Bool) async {
        guard settings.hasGeminiKey else { geminiModels = []; return }
        geminiModels = await GeminiModelCatalog.shared.models(apiKey: settings.geminiAPIKey, refresh: refresh)
    }

    private func loadClaudeModels() async {
        guard settings.hasClaudeKey else { claudeModels = []; return }
        claudeModels = (try? await ClaudeClient(apiKey: settings.claudeAPIKey).listModels()) ?? []
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let provider = try await AgentEngine.makeProvider(settings: settings)
            let reply = try await provider.complete(LLMRequest(
                system: "You are a connection test. Reply with one short friendly sentence.",
                messages: [ChatMessage(role: .user, parts: [.text("Say hello in five words or fewer.")])],
                tools: []
            ))
            let text = reply.parts.compactMap(\.text).joined()
            testResult = "✅ \(provider.modelName): \(text)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

/// Voice in / voice out.
struct VoiceSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    private let voices = VoiceOutput.englishVoices

    var body: some View {
        Section {
            Toggle("Speak replies", isOn: $settings.speakReplies)
            Toggle("Hands-free conversation", isOn: $settings.handsFree)
            Picker("Reply voice", selection: $settings.voiceEngine) {
                Text("Natural (Gemini \(settings.geminiVoiceName))").tag("natural")
                Text("Device voice").tag("device")
            }
            #if os(iOS)
            Picker("Voice & video calls", selection: $settings.liveEngine) {
                Text("Automatic").tag("auto")
                ForEach(LiveEngineKind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if settings.hasOpenAIKey {
                TextField("OpenAI Realtime model", text: $settings.openAIRealtimeModel)
                    .autocorrectionDisabled()
                Picker("OpenAI Realtime voice", selection: $settings.openAIRealtimeVoice) {
                    ForEach(OpenAIRealtimeTransport.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            #endif
            Toggle("Listen for “Hey JARVIS” while open", isOn: $settings.wakeWordEnabled)
            Picker("Device voice", selection: $settings.voiceIdentifier) {
                Text("Automatic (best for language)").tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text("\(voice.name) – \(voice.language)\(voice.quality == .enhanced || voice.quality == .premium ? " ★" : "")")
                        .tag(voice.identifier)
                }
            }
            HStack {
                Image(systemName: "tortoise")
                Slider(value: $settings.speechRate, in: 0.3...0.7)
                Image(systemName: "hare")
            }
            Picker("Listening language", selection: $settings.recognitionLocale) {
                ForEach(SpeechRecognizer.localeOptions) { option in
                    Text(option.name).tag(option.id)
                }
            }
            Button("Preview voice") {
                VoiceOutput.shared.speak("At your service. What shall we build today?")
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Natural voice uses Gemini (or OpenAI) neural speech. Calls: Gemini Live and OpenAI Realtime stream audio both ways – interrupt any time, show things with the camera; Classic works with every brain and attaches the camera view each time you speak. Automatic = Gemini Live, else OpenAI Realtime, else Classic. The wake word works while JARVIS is open.")
        }
    }
}

/// Name and custom instructions.
struct PersonalizationSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Section {
            TextField("What should JARVIS call you?", text: $settings.userName)
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom instructions").font(.subheadline)
                TextEditor(text: $settings.customInstructions)
                    .frame(minHeight: 90)
                    .font(.body)
            }
            Stepper("Max steps per request: \(settings.maxAgentSteps)", value: $settings.maxAgentSteps, in: 3...40)
        } header: {
            Text("Personalisation")
        } footer: {
            Text("e.g. \"Always answer in Arabic\", \"I'm a teacher – make worksheets printable\". Applies to new conversations.")
        }
    }
}

/// Long-term memory management.
struct MemorySettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var memory = MemoryStore.shared
    @State private var newFact = ""

    var body: some View {
        Section {
            Toggle("Use memory", isOn: $settings.memoryEnabled)
            ForEach(memory.items.reversed()) { item in
                Text(item.text)
                    .font(.callout)
                    .contextMenu {
                        Button(role: .destructive) { memory.remove(item.id) } label: { Label("Forget", systemImage: "trash") }
                    }
            }
            .onDelete { offsets in
                let items = Array(memory.items.reversed())
                for index in offsets { memory.remove(items[index].id) }
            }
            HStack {
                TextField("Add something to remember", text: $newFact)
                Button("Add") {
                    memory.add(newFact)
                    newFact = ""
                }
                .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !memory.items.isEmpty {
                Button("Forget everything", role: .destructive) { memory.clear() }
            }
        } header: {
            Text("Memory (\(memory.items.count))")
        } footer: {
            Text("JARVIS remembers preferences and facts you share (\"remember that I'm vegetarian\"). Stored only on this device; used in new conversations.")
        }
    }
}

/// Requests and tokens per brain.
struct UsageSection: View {
    @ObservedObject private var usage = UsageTracker.shared

    var body: some View {
        Section {
            if usage.today.isEmpty {
                Text("No requests yet today.").foregroundColor(.secondary)
            }
            ForEach(Array(usage.today.enumerated()), id: \.offset) { _, item in
                LabeledContent(item.provider.shortName,
                               value: "\(item.entry.requests) requests · \(UsageSection.format(item.entry.tokens)) tokens")
            }
            let week = usage.total(lastDays: 7)
            LabeledContent("Last 7 days", value: "\(week.requests) requests · \(UsageSection.format(week.tokens)) tokens")
            Button("Reset", role: .destructive) { usage.reset() }
        } header: {
            Text("Usage today")
        } footer: {
            Text("Each tool step is one request, so agent tasks use several. Counts are kept on this device only.")
        }
    }

    static func format(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
            : tokens >= 1_000 ? String(format: "%.1fk", Double(tokens) / 1_000) : "\(tokens)"
    }
}
