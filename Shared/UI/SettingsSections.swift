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
            Toggle("Real-time Live voice mode", isOn: $settings.liveVoiceEnabled)
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
            Text("Natural voice uses Gemini's neural speech (needs a Gemini key). Live voice mode streams audio both ways in real time – interrupt any time, show things with the camera. Hands-free: JARVIS listens again after answering. The wake word works only while JARVIS is open and uses on-device recognition when available.")
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
