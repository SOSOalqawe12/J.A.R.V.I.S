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
                Text("Say \"Ask JARVIS\" to Siri, or use the Ask JARVIS action in Shortcuts. Other apps can open jarvis://ask?q=your+request.")
                    .font(.footnote)
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
