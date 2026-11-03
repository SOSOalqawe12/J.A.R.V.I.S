import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Apple Intelligence, iOS 26 / macOS 26):
/// free, private and offline. Small context window, so JARVIS sends a compact
/// prompt and a focused set of tools (called through `<tool_call>` tags).
enum AppleIntelligence {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var status: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Ready – runs entirely on this device."
            case .unavailable(let reason):
                return "Unavailable: \(reason). Needs an Apple Intelligence–capable device with Apple Intelligence turned on."
            @unknown default:
                return "Unavailable on this device."
            }
        }
        return "Needs iOS 26 / macOS 26 or later."
        #else
        return "This build was made without the iOS 26 SDK."
        #endif
    }

    /// Tools small enough to describe within the on-device context window.
    static let toolNames: Set<String> = [
        "create_file", "read_file", "list_files", "append_to_file", "calculate", "get_date_time",
        "get_weather", "set_timer", "add_reminder", "add_calendar_event", "list_calendar_events",
        "remember", "web_search", "create_qr_code"
    ]
}

struct AppleIntelligenceProvider: LLMProvider {
    var kind: ProviderKind { .apple }
    var modelName: String { "Apple on-device model" }

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard AppleIntelligence.isAvailable else { throw LLMError.unavailable(AppleIntelligence.status) }
            let tools = request.tools.filter { AppleIntelligence.toolNames.contains($0.name) }
            let prompt = """
            You are JARVIS, a concise, friendly personal assistant on the user's device. \
            Reply in the user's language. Create real files with tools when asked to make something.
            \(PromptedTools.instructions(for: tools))

            Conversation so far:
            \(PromptedTools.transcript(request.messages, characterBudget: 5_000))
            Assistant:
            """
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let extracted = PromptedTools.extract(PromptedTools.stripReasoning(response.content))
            var parts: [MessagePart] = []
            if !extracted.text.isEmpty { parts.append(.text(extracted.text)) }
            parts.append(contentsOf: extracted.calls.map { .call($0) })
            if parts.isEmpty { throw LLMError.emptyResponse("the on-device model returned nothing") }
            return LLMReply(parts: parts, raw: nil, model: "apple-on-device", stopReason: nil)
        }
        #endif
        throw LLMError.unavailable(AppleIntelligence.status)
    }
}
