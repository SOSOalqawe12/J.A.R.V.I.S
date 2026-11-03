import SwiftUI

/// First-run setup: meet JARVIS, pick a brain, paste a key, learn what to say.
struct OnboardingView: View {
    var onDone: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var page = 0
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        ZStack {
            Theme.backgroundGradient
            TabView(selection: $page) {
                welcome.tag(0)
                brain.tag(1)
                tips.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            CoreOrbView(mode: .idle, size: 190)
            Text("Hello, I'm JARVIS").font(.largeTitle.weight(.bold)).foregroundColor(.white)
            VStack(alignment: .leading, spacing: 12) {
                bullet("doc.badge.plus", "I make real files – notes, PDFs, images, charts, audio – in your JARVIS folder.")
                bullet("waveform", "Talk to me hands-free, even with the camera on.")
                bullet("calendar", "I handle your calendar, reminders, timers, weather and Shortcuts.")
                bullet("lock.shield", "Your keys and memories stay on this device.")
            }
            .padding(.horizontal, 28)
            Spacer()
            primaryButton("Get started") { withAnimation { page = 1 } }
        }
        .padding(.bottom, 50)
    }

    private var brain: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose my brain").font(.title.weight(.bold)).foregroundColor(.white)
                Text("You can change this any time in Settings.").foregroundColor(Theme.secondaryText)

                brainCard(.gemini, title: "Google Gemini", badge: "Recommended · free key",
                          detail: "Chat, images, natural voices and live video calls.") {
                    keyField("Gemini API key", text: $settings.geminiAPIKey)
                    Link("Get a free key at aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.footnote)
                }
                brainCard(.openai, title: "OpenAI", badge: "API key",
                          detail: "GPT models, images, voices and OpenAI Realtime calls.") {
                    keyField("OpenAI API key", text: $settings.openAIAPIKey)
                    Link("Create a key at platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.footnote)
                }
                brainCard(.deepseek, title: "DeepSeek", badge: "API key · low cost",
                          detail: "DeepSeek Chat and Reasoner. JARVIS describes images and the camera for it.") {
                    keyField("DeepSeek API key", text: $settings.deepSeekAPIKey)
                    Link("Create a key at platform.deepseek.com", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                        .font(.footnote)
                }
                brainCard(.claude, title: "Claude", badge: "API key", detail: "Anthropic's Claude models.") {
                    keyField("Claude API key", text: $settings.claudeAPIKey)
                    Link("Create a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.footnote)
                }
                brainCard(.local, title: "Local model", badge: "Ollama · LM Studio",
                          detail: "Your own computer runs the model – private and unlimited.") {
                    TextField("http://192.168.1.20:11434/v1", text: $settings.localBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    Text("On your Mac run Ollama with OLLAMA_HOST=0.0.0.0, then enter its network address.")
                        .font(.caption).foregroundColor(Theme.secondaryText)
                }
                brainCard(.apple, title: "On-device", badge: "Apple Intelligence", detail: AppleIntelligence.status) {
                    EmptyView()
                }

                if let testResult {
                    Text(testResult).font(.footnote).foregroundColor(Theme.secondaryText)
                }
                HStack {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }
                        .buttonStyle(.bordered)
                        .disabled(testing || !settings.isProviderConfigured)
                    Spacer()
                    primaryButton("Continue") { withAnimation { page = 2 } }
                        .disabled(!settings.isProviderConfigured)
                        .opacity(settings.isProviderConfigured ? 1 : 0.5)
                }
            }
            .padding(24)
            .padding(.bottom, 40)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Things to try").font(.title.weight(.bold)).foregroundColor(.white)
            bullet("text.bubble", "“Make a packing list for Paris” – it appears in Files › JARVIS.")
            bullet("paintbrush.pointed", "“Draw a neon city wallpaper for my phone.”")
            bullet("calendar.badge.plus", "“Lunch with Sam tomorrow at 1pm” – added to Calendar.")
            bullet("video", "Tap the waveform, turn on the camera: “What am I looking at?”")
            bullet("mic", "Siri: “Talk to JARVIS”, “Ask JARVIS…”, “JARVIS briefing”.")
            bullet("hand.tap", "Long-press the JARVIS icon for quick actions.")
            Spacer()
            HStack {
                Spacer()
                primaryButton("Start") {
                    settings.onboardingDone = true
                    onDone()
                }
                Spacer()
            }
        }
        .padding(28)
        .padding(.bottom, 40)
    }

    // MARK: Helpers

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 24)
            Text(text).foregroundColor(.white)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundColor(Theme.background)
                .padding(.horizontal, 34)
                .padding(.vertical, 14)
                .background(Capsule().fill(Theme.accent))
        }
    }

    private func keyField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack {
            SecureField(placeholder, text: text)
                .textContentType(.password)
                .autocorrectionDisabled()
            Button {
                if let pasted = UIPasteboard.general.string { text.wrappedValue = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func brainCard<Content: View>(_ kind: ProviderKind, title: String, badge: String, detail: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        let selected = settings.provider == kind
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                settings.provider = kind
                testResult = nil
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(title).font(.headline).foregroundColor(.white)
                            Text(badge).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent.opacity(0.2)))
                                .foregroundColor(Theme.accent)
                        }
                        Text(detail).font(.footnote).foregroundColor(Theme.secondaryText).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    if settings.isConfigured(kind) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    }
                }
            }
            .buttonStyle(.plain)
            if selected { content() }
        }
        .padding(14)
        .hudPanel(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.accent : .clear, lineWidth: 1.5))
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let provider = try await AgentEngine.makeProvider(settings: settings)
            let reply = try await provider.complete(LLMRequest(
                system: "Reply with one short friendly sentence.",
                messages: [ChatMessage(role: .user, parts: [.text("Say hello in five words or fewer.")])],
                tools: []
            ))
            testResult = "✅ " + reply.parts.compactMap(\.text).joined()
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
