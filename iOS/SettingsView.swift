import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = ConversationStore.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    CoreOrbView(mode: .idle, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("JARVIS").font(.title2.weight(.bold))
                        Text("Your personal AI that makes real files.").font(.footnote).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            AIProviderSettingsSections()
            VoiceSettingsSection()
            PersonalizationSection()
            MemorySettingsSection()
            UsageSection()

            Section {
                Toggle("Require Face ID", isOn: $settings.appLockEnabled)
                Toggle("Haptics", isOn: $settings.hapticsEnabled)
            } header: {
                Text("Privacy & feel")
            } footer: {
                Text("API keys are stored in the iOS Keychain on this device only.")
            }

            Section {
                Button("Open JARVIS folder in Files") {
                    if let url = URL(string: "shareddocuments://" + Workspace.shared.root.path) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Clear conversation history (\(store.summaries.count))", role: .destructive) {
                    confirmClear = true
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Files JARVIS makes live in Files › On My iPhone › JARVIS. Deleting conversations doesn't delete files.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Try saying to Siri:").font(.footnote.weight(.semibold))
                    Text("• “Talk to JARVIS” – live voice\n• “Ask JARVIS” – any request\n• “JARVIS briefing”\n• “Generate an image with JARVIS”\n• “Add a note to JARVIS”\n• “Tell JARVIS to remember something”\n• “Scan a document with JARVIS”")
                        .font(.footnote)
                    Text("All actions are also in the Shortcuts app (incl. “Process File with JARVIS” for the share sheet). Assign “Talk to JARVIS” to the Action button. Links: jarvis://voice, jarvis://briefing, jarvis://ask?q=…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Siri & Shortcuts")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Delete all conversations?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                ChatViewModel.shared.newConversation()
                store.deleteAll()
            }
        }
    }
}
