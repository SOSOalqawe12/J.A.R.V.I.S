import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Markdown-ish text

struct MarkdownText: View {
    let text: String

    private struct Block: Identifiable {
        let id: Int
        let isCode: Bool
        let content: String
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let pieces = text.components(separatedBy: "```")
        for (index, piece) in pieces.enumerated() {
            let isCode = index % 2 == 1
            var content = piece
            if isCode, let newline = content.firstIndex(of: "\n") {
                // Drop the language tag after the opening fence.
                let firstLine = content[..<newline]
                if !firstLine.contains(" ") { content = String(content[content.index(after: newline)...]) }
            }
            content = content.trimmingCharacters(in: .newlines)
            if !content.isEmpty { result.append(Block(id: index, isCode: isCode, content: content)) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                if block.isCode {
                    CodeBlockView(code: block.content)
                } else {
                    Text(MarkdownText.attributed(block.content))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        var output = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            var isHeading = false
            if let range = line.range(of: "^#{1,6} ", options: .regularExpression) {
                line.removeSubrange(range)
                isHeading = true
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }
            var piece = (try? AttributedString(
                markdown: line,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(line)
            if isHeading { piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .headline }
            output.append(piece)
            if index < lines.count - 1 { output.append(AttributedString("\n")) }
        }
        return output
    }
}

struct CodeBlockView: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                Clipboard.copy(code)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - File chips

struct FileThumbnail: View {
    let url: URL
    var maxPixel: CGFloat = 400
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: FileThumbnail.symbol(for: url))
                    .font(.title2)
                    .foregroundColor(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.panelHighlight)
            }
        }
        .task(id: url) {
            let target = url
            let pixels = maxPixel
            image = await Task.detached(priority: .utility) {
                ImageCoder.thumbnail(url: target, maxPixel: pixels)
            }.value
        }
    }

    static func symbol(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .html) { return "globe" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .commaSeparatedText) || type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .calendarEvent) { return "calendar" }
        if type.conforms(to: .vCard) { return "person.crop.square" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

struct FileChip: View {
    let relativePath: String
    var onOpen: (URL) -> Void

    private var url: URL? { try? Workspace.shared.resolve(relativePath) }

    var body: some View {
        if let url {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            Button {
                if exists { onOpen(url) }
            } label: {
                if isImage && exists {
                    VStack(alignment: .leading, spacing: 6) {
                        FileThumbnail(url: url, maxPixel: 700)
                            .frame(maxWidth: 280, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(url.lastPathComponent).font(.caption).foregroundColor(Theme.secondaryText).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 10) {
                        FileThumbnail(url: url, maxPixel: 120)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.subheadline.weight(.semibold)).foregroundColor(Theme.text).lineLimit(1)
                            Text(exists ? (relativePath as NSString).deletingLastPathComponent.isEmpty ? "JARVIS folder" : (relativePath as NSString).deletingLastPathComponent : "Moved or deleted")
                                .font(.caption).foregroundColor(Theme.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "eye").foregroundColor(Theme.accent)
                    }
                    .padding(10)
                    .frame(maxWidth: 320)
                    .hudPanel(cornerRadius: 12)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if exists {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    #if os(macOS)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    #endif
                }
            }
        }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    var onOpen: (URL) -> Void
    var onRetry: (() -> Void)?

    var body: some View {
        if message.isLocalNotice {
            notice
        } else {
            switch message.role {
            case .user: userBubble
            case .assistant: assistantBubble
            case .tool: toolResults
            }
        }
    }

    private var notice: some View {
        HStack(spacing: 10) {
            Text(message.visibleText)
                .font(.footnote)
                .foregroundColor(message.visibleText.hasPrefix("⚠️") ? Theme.warm : Theme.secondaryText)
                .textSelection(.enabled)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(message.attachments) { attachment in
                    AttachmentPreview(attachment: attachment)
                }
                let text = message.visibleText
                if !text.isEmpty {
                    Text(text)
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.userBubble)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            CoreOrbView(mode: .idle, size: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                let text = message.visibleText
                if !text.isEmpty {
                    MarkdownText(text: text)
                        .foregroundColor(Theme.text)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallChip(call: call)
                }
            }
            Spacer(minLength: 24)
        }
    }

    private var toolResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(message.toolResults.enumerated()), id: \.offset) { _, result in
                ToolResultView(result: result, onOpen: onOpen)
            }
        }
        .padding(.leading, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolCallChip: View {
    let call: ToolCall

    private var detail: String {
        for key in ["path", "query", "url", "source_path", "command", "name", "app", "expression", "title"] {
            if let value = call.arguments[key]?.stringValue, !value.isEmpty {
                return value.count > 60 ? String(value.prefix(58)) + "…" : value
            }
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ToolCallChip.icon(for: call.name))
            Text(call.name.replacingOccurrences(of: "_", with: " ")).fontWeight(.semibold)
            if !detail.isEmpty {
                Text(detail).foregroundColor(Theme.secondaryText).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundColor(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.accent.opacity(0.1)))
    }

    static func icon(for name: String) -> String {
        switch name {
        case "generate_image", "edit_image": return "paintbrush.pointed"
        case "create_pdf": return "doc.richtext"
        case "create_chart": return "chart.bar"
        case "create_qr_code": return "qrcode"
        case "text_to_speech": return "waveform"
        case "web_search": return "magnifyingglass"
        case "fetch_url", "download_file", "open_url": return "globe"
        case "capture_screen": return "camera.viewfinder"
        case "run_shell_command": return "terminal"
        case "run_applescript": return "applescript"
        case "delete_file": return "trash"
        case "calculate": return "function"
        default: return "gearshape"
        }
    }
}

struct ToolResultView: View {
    let result: ToolResult
    var onOpen: (URL) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !result.files.isEmpty {
                ForEach(result.files, id: \.self) { path in
                    FileChip(relativePath: path, onOpen: onOpen)
                }
            }
            if result.isError || result.files.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: result.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        Text(expanded ? result.output : (result.output.components(separatedBy: "\n").first ?? ""))
                            .lineLimit(expanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                    .font(.caption)
                    .foregroundColor(result.isError ? Theme.warm : Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            ForEach(result.images) { image in
                AttachmentPreview(attachment: image)
            }
        }
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment

    var body: some View {
        if attachment.isImage, let image = Image(imageData: attachment.data) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Label(attachment.name, systemImage: "paperclip")
                .font(.caption)
                .padding(8)
                .hudPanel(cornerRadius: 10)
        }
    }
}

struct ThinkingRow: View {
    let status: String
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CoreOrbView(mode: .thinking, size: 34)
            Text(status.isEmpty ? "Thinking…" : status)
                .font(.subheadline)
                .foregroundColor(Theme.secondaryText)
            Spacer()
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.warm)
        }
        .padding(.vertical, 6)
    }
}
