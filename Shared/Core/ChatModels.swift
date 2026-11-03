import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case gemini
    case claude
    case claudeCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .claude: return "Claude (API key)"
        case .claudeCode: return "Claude (subscription via Claude Code)"
        }
    }

    var shortName: String {
        switch self {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code"
        }
    }

    /// Providers that can be used on the current platform.
    static var available: [ProviderKind] {
        #if os(macOS)
        return [.gemini, .claude, .claudeCode]
        #else
        return [.gemini, .claude]
        #endif
    }
}

enum ChatRole: String, Codable {
    case user
    case assistant
    case tool
}

struct Attachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var mimeType: String
    var data: Data

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isPDF: Bool { mimeType == "application/pdf" }
    var isText: Bool {
        mimeType.hasPrefix("text/") || ["application/json", "application/xml", "application/x-yaml"].contains(mimeType)
    }
}

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: JSONValue
    /// Gemini "thought signature" that must be echoed back with the call.
    var thoughtSignature: String?

    /// IDs we generated locally (because the provider did not supply one)
    /// start with this prefix and are not sent back to Gemini.
    static let localPrefix = "local_"
    var hasProviderID: Bool { !id.hasPrefix(ToolCall.localPrefix) }

    static func makeLocalID() -> String {
        localPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

struct ToolResult: Codable, Hashable {
    var callID: String
    var name: String
    var output: String
    var isError: Bool = false
    /// Images handed back to the model (e.g. a fresh screenshot).
    var images: [Attachment] = []
    /// Workspace-relative paths of files this tool created or changed.
    var files: [String] = []
}

struct MessagePart: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case text
        case attachment
        case toolCall
        case toolResult
    }

    var id = UUID()
    var kind: Kind
    var text: String?
    var attachment: Attachment?
    var toolCall: ToolCall?
    var toolResult: ToolResult?
    var thoughtSignature: String?
    /// Sent to the model but not rendered in the chat (e.g. date/screen context).
    var hidden: Bool = false

    static func text(_ text: String, hidden: Bool = false, signature: String? = nil) -> MessagePart {
        MessagePart(kind: .text, text: text, thoughtSignature: signature, hidden: hidden)
    }

    static func attachment(_ attachment: Attachment) -> MessagePart {
        MessagePart(kind: .attachment, attachment: attachment)
    }

    static func call(_ call: ToolCall) -> MessagePart {
        MessagePart(kind: .toolCall, toolCall: call)
    }

    static func result(_ result: ToolResult) -> MessagePart {
        MessagePart(kind: .toolResult, toolResult: result)
    }
}

struct ChatMessage: Codable, Hashable, Identifiable {
    var id = UUID()
    var role: ChatRole
    var parts: [MessagePart]
    var date = Date()
    /// Which provider produced this (assistant) message.
    var provider: ProviderKind?
    /// Model that produced this message.
    var model: String?
    /// The provider's raw content, replayed verbatim to the same provider so
    /// thinking blocks / thought signatures stay valid.
    var providerRaw: JSONValue?
    /// Local error/notice bubbles: shown in the UI but never sent to a model.
    var isLocalNotice: Bool = false

    var visibleText: String {
        parts.filter { $0.kind == .text && !$0.hidden }.compactMap(\.text).joined(separator: "\n")
    }

    var toolCalls: [ToolCall] { parts.compactMap(\.toolCall) }
    var toolResults: [ToolResult] { parts.compactMap(\.toolResult) }
    var attachments: [Attachment] { parts.compactMap(\.attachment) }

    static func notice(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, parts: [.text(text)], isLocalNotice: true)
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = "New conversation"
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []
    /// Frozen at creation so the prompt prefix stays byte-identical across turns
    /// (required for prompt caching and for replaying thinking blocks).
    var systemPrompt: String
    /// Session id when chatting through the Claude Code CLI.
    var claudeCodeSessionID: String?
    var origin: String?
    /// AssistantMode raw value (nil = default JARVIS).
    var mode: String?
}

struct ConversationSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var updated: Date
    var origin: String?
}
