import SwiftUI
import AppKit

/// Panel subclass that can take keyboard focus and closes on Esc.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// A Spotlight-style floating command bar summoned with ⌃⌥J from anywhere.
@MainActor
final class CommandPanel {
    static let shared = CommandPanel()

    private let panel: KeyablePanel

    private init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: CommandBarView())
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.maxY - panel.frame.height - frame.height * 0.12))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .jarvisFocusCommandBar, object: nil)
    }

    func hide() { panel.orderOut(nil) }
}

extension Notification.Name {
    static let jarvisFocusCommandBar = Notification.Name("jarvisFocusCommandBar")
}

struct CommandBarView: View {
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var speech = ChatViewModel.shared.speech
    @State private var text = ""
    @FocusState private var focused: Bool

    private var lastReply: ChatMessage? {
        chat.conversation.messages.last { $0.role == .assistant && !$0.visibleText.isEmpty }
    }

    private var lastFiles: [String] {
        Array(chat.recentFiles.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CoreOrbView(mode: chat.isRunning ? .thinking : (speech.isRecording ? .listening : .idle),
                            level: CGFloat(speech.level), size: 40)
                TextField("Ask JARVIS… (⏎ to send)", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.white)
                    .focused($focused)
                    .onSubmit(send)
                Button {
                    chat.includeScreen.toggle()
                } label: {
                    Image(systemName: chat.includeScreen ? "eye.fill" : "eye.slash")
                        .foregroundColor(chat.includeScreen ? Theme.accent : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Include a screenshot of your screen")
                Button {
                    chat.toggleListening()
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .foregroundColor(speech.isRecording ? Theme.warm : Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 18))

            if speech.isRecording {
                Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                    .foregroundColor(Theme.secondaryText)
            }

            Divider().overlay(Theme.accent.opacity(0.25))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if chat.isRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(chat.status.isEmpty ? "Thinking…" : chat.status).foregroundColor(Theme.secondaryText)
                            Spacer()
                            Button("Stop") { chat.stop() }
                        }
                    }
                    if let reply = lastReply {
                        MarkdownText(text: reply.visibleText)
                            .foregroundColor(.white)
                    } else {
                        Text("Try: “What's on my screen?”, “Summarise this page into a PDF”, “Make a to-do list from this email”.")
                            .foregroundColor(Theme.secondaryText)
                    }
                    ForEach(lastFiles, id: \.self) { path in
                        FileChip(relativePath: path) { url in _ = NSWorkspace.shared.open(url) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("⌃⌥J toggle · ⌃⌥S analyze screen · esc close")
                    .font(.caption2)
                    .foregroundColor(Theme.secondaryText)
                Spacer()
                Button("Open JARVIS") { MacAppState.shared.showMainWindow(section: .chat) }
                    .buttonStyle(.link)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.background.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        )
        .onReceive(NotificationCenter.default.publisher(for: .jarvisFocusCommandBar)) { _ in
            focused = true
        }
    }

    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        text = ""
        chat.send(request)
    }
}
