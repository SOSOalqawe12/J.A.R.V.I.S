import Foundation

struct ToolOutput {
    var text: String
    var images: [Attachment] = []
    var files: [String] = []
}

enum ToolError: LocalizedError {
    case missingArgument(String)
    case invalid(String)
    case denied(String)
    case needsGeminiKey(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): return "Missing required argument \"\(name)\"."
        case .invalid(let message): return message
        case .denied(let action): return "The user denied permission to \(action)."
        case .needsGeminiKey(let feature): return "\(feature) needs a Gemini API key. Ask the user to add one in JARVIS Settings."
        }
    }
}

/// Everything a tool needs while running.
struct ToolContext {
    let workspace: Workspace
    let settings: AppSettings
    let approvals: ApprovalCenter

    var gemini: GeminiClient? {
        settings.hasGeminiKey ? GeminiClient(apiKey: settings.geminiAPIKey) : nil
    }

    func requireGemini(_ feature: String) throws -> GeminiClient {
        guard let gemini else { throw ToolError.needsGeminiKey(feature) }
        return gemini
    }

    func geminiModel(_ role: GeminiModelRole) async -> String {
        let preferred: String
        switch role {
        case .chat: preferred = settings.geminiChatModel
        case .image: preferred = settings.geminiImageModel
        case .tts: preferred = settings.geminiTTSModel
        }
        return await GeminiModelCatalog.shared.resolve(role, preferred: preferred, apiKey: settings.geminiAPIKey)
    }

    func approve(_ title: String, detail: String) async throws {
        let approved = await approvals.requestApproval(title: title, detail: detail)
        if !approved { throw ToolError.denied(title.lowercased()) }
    }
}

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    /// Short human label shown in the chat while running ("Creating file…").
    var activityLabel: String { get }
    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput
}

extension AgentTool {
    var spec: ToolSpec { ToolSpec(name: name, description: description, parameters: parameters) }
    var activityLabel: String { "Working" }
}

extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue else { throw ToolError.missingArgument(key) }
        return value
    }

    func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        self[key]?.boolValue ?? defaultValue
    }

    func int(_ key: String) -> Int? { self[key]?.intValue }

    func stringArray(_ key: String) -> [String] {
        if let items = self[key]?.arrayValue { return items.compactMap(\.stringValue) }
        if let single = self[key]?.stringValue, !single.isEmpty {
            return single.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }
}

/// Builds the tool list for a platform.
enum Toolbox {
    static func sharedTools() -> [AgentTool] {
        [
            CreateFileTool(),
            ReadFileTool(),
            AppendFileTool(),
            EditFileTool(),
            ListFilesTool(),
            CreateFolderTool(),
            MoveFileTool(),
            CopyFileTool(),
            DeleteFileTool(),
            ZipFolderTool(),
            GenerateImageTool(),
            EditImageTool(),
            CreatePDFTool(),
            CreateChartTool(),
            CreateQRCodeTool(),
            TextToSpeechTool(),
            WebSearchTool(),
            FetchURLTool(),
            DownloadFileTool(),
            ClipboardTool(),
            DateTimeTool(),
            CalculatorTool()
        ]
    }
}
