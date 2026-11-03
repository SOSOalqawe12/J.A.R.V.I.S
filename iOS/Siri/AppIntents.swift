import AppIntents
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Headless agent runs (Siri / Shortcuts)

@MainActor
enum HeadlessJarvis {
    struct Result {
        var answer: String
        var files: [String]
    }

    static func run(_ request: String, attachments: [Attachment] = [], origin: String = "siri") async throws -> Result {
        let settings = AppSettings.shared
        var conversation = Conversation(systemPrompt: SystemPrompts.make(settings: settings) +
            "\n\nYou are answering through Siri/Shortcuts: the reply will be spoken, so keep it to one to three short sentences.")
        conversation.title = "Siri: " + ChatViewModel.title(for: request, attachments: attachments)
        conversation.origin = origin
        var parts: [MessagePart] = [.text(SystemPrompts.turnContext(), hidden: true), .text(request)]
        parts.append(contentsOf: attachments.map { .attachment($0) })
        conversation.messages.append(ChatMessage(role: .user, parts: parts))

        let approvals = ApprovalCenter.shared
        approvals.headless = true
        defer { approvals.headless = false }

        let provider = try await AgentEngine.makeProvider(settings: settings)
        let engine = AgentEngine(
            tools: Toolbox.sharedTools() + iOSTools.all,
            context: ToolContext(workspace: Workspace.shared, settings: settings, approvals: approvals)
        )
        var created: [String] = []
        _ = try await engine.run(
            history: conversation.messages,
            system: conversation.systemPrompt,
            sessionID: nil,
            provider: provider,
            maxSteps: settings.maxAgentSteps,
            onMessage: { message in
                conversation.messages.append(message)
                for result in message.toolResults { created.append(contentsOf: result.files) }
            },
            onStatus: { _ in }
        )
        ConversationStore.shared.save(conversation)
        ChatViewModel.shared.noteCreatedFiles(created)
        var answer = conversation.messages.last(where: { $0.role == .assistant && !$0.isLocalNotice })?.visibleText ?? ""
        if answer.isEmpty { answer = created.isEmpty ? "Done." : "Done – saved \(created.joined(separator: ", "))." }
        return Result(answer: VoiceOutput.speakable(answer), files: created)
    }

    static func intentFiles(_ paths: [String]) -> [IntentFile] {
        paths.compactMap { path in
            guard let url = try? Workspace.shared.resolve(path), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return IntentFile(fileURL: url, filename: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
        }
    }
}

/// Visual result shown under Siri's answer.
struct JarvisSnippetView: View {
    let text: String
    let files: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CoreOrbView(mode: .idle, size: 28)
                Text("JARVIS").font(.headline)
            }
            Text(text).font(.callout).lineLimit(8)
            ForEach(files.prefix(3), id: \.self) { path in
                if let url = try? Workspace.shared.resolve(path) {
                    HStack(spacing: 10) {
                        if let image = ImageCoder.thumbnail(url: url, maxPixel: 240) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: FileThumbnail.symbol(for: url))
                                .font(.title2)
                                .frame(width: 56, height: 56)
                        }
                        Text(path).font(.caption).lineLimit(2)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Intents

struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask JARVIS"
    static let description: IntentDescription? = IntentDescription("Ask JARVIS anything or have it make something – notes, PDFs, images, audio, calendar events, reminders…")
    static let openAppWhenRun = false

    @Parameter(title: "Request", requestValueDialog: "What would you like me to do?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let result = try await HeadlessJarvis.run(request)
        return .result(value: result.answer, dialog: "\(result.answer)", view: JarvisSnippetView(text: result.answer, files: result.files))
    }
}

struct TalkToJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to JARVIS"
    static let description: IntentDescription? = IntentDescription("Open JARVIS in live voice mode.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.perform(.voice(nil))
        return .result()
    }
}

enum ImageShape: String, AppEnum {
    case square, portrait, landscape, widescreen

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Image Shape"
    static var caseDisplayRepresentations: [ImageShape: DisplayRepresentation] = [
        .square: "Square",
        .portrait: "Portrait (phone wallpaper)",
        .landscape: "Landscape",
        .widescreen: "Widescreen"
    ]

    var ratio: String {
        switch self {
        case .square: return "1:1"
        case .portrait: return "9:16"
        case .landscape: return "4:3"
        case .widescreen: return "16:9"
        }
    }
}

struct GenerateImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate Image with JARVIS"
    static let description: IntentDescription? = IntentDescription("Create a picture with Gemini and save it in the JARVIS folder.")
    static let openAppWhenRun = false

    @Parameter(title: "Description", requestValueDialog: "What should I draw?")
    var prompt: String

    @Parameter(title: "Shape", default: .square)
    var shape: ImageShape

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog & ShowsSnippetView {
        let settings = AppSettings.shared
        guard settings.hasGeminiKey else { throw ToolError.needsGeminiKey("Image generation") }
        let context = ToolContext(workspace: .shared, settings: settings, approvals: .shared)
        let name = ChatViewModel.title(for: prompt, attachments: []).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "…", with: "")
        let output = try await GenerateImageTool().run([
            "prompt": .string(prompt),
            "path": .string("Images/\(name).png"),
            "aspect_ratio": .string(shape.ratio)
        ], context: context)
        ChatViewModel.shared.noteCreatedFiles(output.files)
        guard let file = HeadlessJarvis.intentFiles(output.files).first else { throw ToolError.invalid("The image wasn't saved.") }
        return .result(value: file, dialog: "Here's your image. It's saved in your JARVIS folder.",
                       view: JarvisSnippetView(text: prompt, files: output.files))
    }
}

struct MakeWithJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Files with JARVIS"
    static let description: IntentDescription? = IntentDescription("Ask JARVIS to create something and get the created files back – great for chaining Shortcuts actions.")
    static let openAppWhenRun = false

    @Parameter(title: "What to make", requestValueDialog: "What should I make?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let result = try await HeadlessJarvis.run(request + "\n(Save the result as a file.)")
        return .result(value: HeadlessJarvis.intentFiles(result.files), dialog: "\(result.answer)")
    }
}

struct ProcessFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Process File with JARVIS"
    static let description: IntentDescription? = IntentDescription("Give JARVIS a photo, PDF or document (e.g. from the Share Sheet) with an instruction: summarise, translate, extract text, describe, edit…")
    static let openAppWhenRun = false

    @Parameter(title: "File", supportedTypeIdentifiers: ["public.image", "com.adobe.pdf", "public.text", "public.data"])
    var file: IntentFile

    @Parameter(title: "Instruction", default: "Summarise this")
    var instruction: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = file.data
        let name = file.filename
        let mime = file.type?.preferredMIMEType ?? Workspace.mimeType(for: URL(fileURLWithPath: name))
        var attachment = Attachment(name: name, mimeType: mime, data: data)
        if mime.hasPrefix("image/"), let prepared = ImageCoder.preparedForModel(data) {
            attachment = Attachment(name: name, mimeType: prepared.mimeType, data: prepared.data)
        }
        let result = try await HeadlessJarvis.run(instruction, attachments: [attachment], origin: "shortcut")
        return .result(value: result.answer, dialog: "\(result.answer)")
    }
}

struct QuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note to JARVIS"
    static let description: IntentDescription? = IntentDescription("Instantly save a note to Notes/Quick notes.md in the JARVIS folder.")
    static let openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What's the note?")
    var note: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let url = try Workspace.shared.resolve("Notes/Quick notes.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "- [\(formatter.string(from: Date()))] \(note)\n"
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } else {
            try ("# Quick notes\n\n" + entry).write(to: url, atomically: true, encoding: .utf8)
        }
        ChatViewModel.shared.noteCreatedFiles(["Notes/Quick notes.md"])
        return .result(dialog: "Noted.")
    }
}

struct DailyBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "JARVIS Briefing"
    static let description: IntentDescription? = IntentDescription("Today's date, calendar, reminders, weather and headlines.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await HeadlessJarvis.run(ChatViewModel.briefingPrompt, origin: "briefing")
        return .result(value: result.answer, dialog: "\(result.answer)")
    }
}

struct RememberIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell JARVIS to Remember"
    static let description: IntentDescription? = IntentDescription("Save something to JARVIS's long-term memory.")
    static let openAppWhenRun = false

    @Parameter(title: "Fact", requestValueDialog: "What should I remember?")
    var fact: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MemoryStore.shared.add(fact)
        return .result(dialog: "I'll remember that.")
    }
}

struct ScanDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan Document with JARVIS"
    static let description: IntentDescription? = IntentDescription("Open the document scanner; the scan is saved as a PDF with its text.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.perform(.scan)
        return .result()
    }
}

// MARK: - Siri phrases

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToJarvisIntent(),
            phrases: ["Talk to \(.applicationName)", "Start \(.applicationName)", "Call \(.applicationName)"],
            shortTitle: "Talk to JARVIS",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something", "Hey \(.applicationName)"],
            shortTitle: "Ask JARVIS",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: DailyBriefingIntent(),
            phrases: ["\(.applicationName) briefing", "Brief me with \(.applicationName)", "Good morning \(.applicationName)"],
            shortTitle: "Briefing",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: GenerateImageIntent(),
            phrases: ["Generate an image with \(.applicationName)", "Draw something with \(.applicationName)"],
            shortTitle: "Generate Image",
            systemImageName: "paintbrush.pointed"
        )
        AppShortcut(
            intent: QuickNoteIntent(),
            phrases: ["Add a note to \(.applicationName)", "Take a note with \(.applicationName)"],
            shortTitle: "Quick Note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: RememberIntent(),
            phrases: ["Tell \(.applicationName) to remember something", "\(.applicationName) remember this"],
            shortTitle: "Remember",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: MakeWithJarvisIntent(),
            phrases: ["Make something with \(.applicationName)", "Create a file with \(.applicationName)"],
            shortTitle: "Make Files",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: ScanDocumentIntent(),
            phrases: ["Scan a document with \(.applicationName)", "\(.applicationName) scan"],
            shortTitle: "Scan Document",
            systemImageName: "doc.viewfinder"
        )
    }
}
