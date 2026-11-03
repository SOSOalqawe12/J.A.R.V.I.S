import SwiftUI
import AppKit
import AVFoundation
import UserNotifications

struct MacSettingsView: View {
    var body: some View {
        TabView {
            Form {
                AIProviderSettingsSections()
                ClaudeCodeSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "brain") }
            Form {
                VoiceSettingsSection()
                PersonalizationSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Voice & You", systemImage: "waveform") }
            Form {
                ScreenWatchSettingsSection()
                MacControlSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Screen & Control", systemImage: "eye") }
            Form { PermissionsSection() }
                .formStyle(.grouped)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .padding(8)
    }
}

struct ClaudeCodeSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        Section {
            TextField("Path to `claude` (leave empty to auto-detect)", text: $settings.claudeCodePath)
            TextField("Model (optional, e.g. opus or sonnet)", text: $settings.claudeCodeModel)
            Toggle("Allow Claude Code to run shell commands (Bash)", isOn: $settings.claudeCodeAllowBash)
            HStack {
                Button(checking ? "Checking…" : "Check installation") {
                    checking = true
                    Task {
                        checkResult = await ClaudeCodeProvider.checkInstallation(customPath: settings.claudeCodePath)
                        checking = false
                    }
                }
                .disabled(checking)
                Link("Install Claude Code", destination: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
            }
            if let checkResult {
                Text(checkResult).font(.caption).textSelection(.enabled)
            }
        } header: {
            Text("Claude subscription (Claude Code)")
        } footer: {
            Text("Pick “Claude Code” as the brain to use your Claude Pro/Max plan instead of an API key. JARVIS runs the official `claude` CLI in your JARVIS folder; run `claude` once in Terminal to sign in.")
        }
    }
}

struct ScreenWatchSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Section {
            Picker("Check the screen every", selection: $settings.watchInterval) {
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("90 seconds").tag(90.0)
                Text("3 minutes").tag(180.0)
                Text("5 minutes").tag(300.0)
                Text("10 minutes").tag(600.0)
            }
            Toggle("Notify me about new suggestions", isOn: $settings.watchNotifications)
            Toggle("Speak new suggestions", isOn: $settings.watchSpeakSuggestions)
            TextField("Current goal (helps JARVIS focus)", text: $settings.watchFocus)
            TextField("Never capture these apps (comma separated)", text: $settings.privacyBlocklist)
        } header: {
            Text("Screen Watch")
        } footer: {
            Text("Watch mode skips analysis when the screen hasn't changed or you've been away for 5+ minutes, to save tokens. JARVIS's own windows are never captured.")
        }
    }
}

struct MacControlSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Section {
            Toggle("Run shell commands & AppleScript without asking", isOn: $settings.autoApproveActions)
            HStack {
                TextField("JARVIS folder", text: $settings.workspacePath, prompt: Text("~/Documents/JARVIS"))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.workspacePath = url.path
                        Workspace.shared.reloadRoot()
                    }
                }
                Button("Open") { NSWorkspace.shared.open(Workspace.shared.root) }
            }
        } header: {
            Text("Mac control")
        } footer: {
            Text("Leave auto-approve off unless you fully trust what you ask for: commands can change files and settings. Global shortcuts: ⌃⌥J command bar · ⌃⌥S analyze screen · ⌃⌥V talk.")
        }
        .onChange(of: settings.workspacePath) { _, _ in Workspace.shared.reloadRoot() }
    }
}

struct PermissionsSection: View {
    @State private var screen = ScreenCapture.hasPermission
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var notifications = false

    var body: some View {
        Section {
            permissionRow("Screen Recording", granted: screen, detail: "Lets JARVIS see your screen.") {
                ScreenCapture.requestPermission()
                ScreenCapture.openPrivacySettings()
            }
            permissionRow("Microphone & Speech", granted: microphone, detail: "Talk to JARVIS.") {
                Task { microphone = await SpeechRecognizer.requestPermissions() }
            }
            permissionRow("Notifications", granted: notifications, detail: "Screen Watch alerts.") {
                Task {
                    notifications = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                }
            }
            Button("Re-check") { refresh() }
        } header: {
            Text("Permissions")
        } footer: {
            Text("After an update you may need to re-enable Screen Recording, because unsigned builds get a new signature each time. Automation prompts appear the first time JARVIS controls another app.")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        screen = ScreenCapture.hasPermission
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notifications = status == .authorized || status == .provisional
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : Theme.warm)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted { Button("Grant", action: action) }
        }
    }
}
