import Foundation

/// Minimal REST client for the Claude Messages API (api.anthropic.com).
/// Swift has no official Anthropic SDK, so this talks raw HTTP.
struct ClaudeClient {
    static let defaultModel = "claude-opus-5-5"
    static let apiVersion = "2026-10-21"
    static let suggestedModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    /// Models that accept `fallbacks: "default"` (server-side refusal fallback).
    static let defaultFallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    let apiKey: String

    static func supportsEffort(_ model: String) -> Bool {
        ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6", "opus-4-5", "sonnet-5", "sonnet-4-6", "haiku-5", "fable", "mythos"]
            .contains { model.contains($0) }
    }

    static func supportsDynamicWebSearch(_ model: String) -> Bool {
        ["opus-5", "opus-4-8", "opus-4-7", "opus-4-6", "sonnet-5", "sonnet-4-6"].contains { model.contains($0) }
    }

    static func errorMessage(_ json: JSONValue) -> String? {
        json["error"]?["message"]?.stringValue
    }

    private func headers(betas: [String]) -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": ClaudeClient.apiVersion
        ]
        if !betas.isEmpty { headers["anthropic-beta"] = betas.joined(separator: ",") }
        return headers
    }

    func createMessage(_ body: JSONValue, betas: [String] = []) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.claude) }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let request = HTTP.jsonRequest(url: url, headers: headers(betas: betas), body: body)
        return try await HTTP.send(request, errorParser: ClaudeClient.errorMessage)
    }

    struct ModelInfo: Hashable, Identifiable {
        let id: String
        let displayName: String
    }

    func listModels() async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.claude) }
        var models: [ModelInfo] = []
        var afterID: String?
        for _ in 0..<5 {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = items
            let request = HTTP.jsonRequest(url: components.url!, method: "GET", headers: headers(betas: []), body: nil)
            let json = try await HTTP.send(request, errorParser: ClaudeClient.errorMessage)
            for model in json["data"]?.arrayValue ?? [] {
                guard let id = model["id"]?.stringValue else { continue }
                models.append(ModelInfo(id: id, displayName: model["display_name"]?.stringValue ?? id))
            }
            guard json["has_more"]?.boolValue == true, let last = json["last_id"]?.stringValue else { break }
            afterID = last
        }
        return models
    }

    /// One-shot web search using Claude's server-side web search tool.
    func webSearch(_ query: String, model: String) async throws -> String {
        let toolType = ClaudeClient.supportsDynamicWebSearch(model) ? "web_search_20260209" : "web_search_20250305"
        var messages: [JSONValue] = [[
            "role": "user",
            "content": .string("Search the web and answer with concrete facts, numbers, dates and the source URLs. Query: \(query)")
        ]]
        for _ in 0..<4 {
            let body: JSONValue = [
                "model": .string(model),
                "max_tokens": 8000,
                "messages": .array(messages),
                "tools": [["type": .string(toolType), "name": "web_search", "max_uses": 5]]
            ]
            let json = try await createMessage(body)
            let content = json["content"]?.arrayValue ?? []
            if json["stop_reason"]?.stringValue == "pause_turn" {
                messages.append(["role": "assistant", "content": .array(content)])
                continue
            }
            if json["stop_reason"]?.stringValue == "refusal" { throw LLMError.refused("Search declined.") }
            let text = content.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
            if text.isEmpty { throw LLMError.emptyResponse("search returned nothing") }
            return text
        }
        throw LLMError.emptyResponse("search did not finish")
    }
}

// MARK: - Chat provider with tool use

struct ClaudeProvider: LLMProvider {
    let client: ClaudeClient
    let model: String
    let effort: String
    let useRefusalFallback: Bool

    var kind: ProviderKind { .claude }
    var modelName: String { model }

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": 16000,
            "messages": .array(ClaudeProvider.messages(from: request.messages)),
            // Automatic prompt caching of the growing conversation prefix.
            "cache_control": ["type": "ephemeral"]
        ]
        if !request.system.isEmpty { body["system"] = .string(request.system) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool -> JSONValue in
                ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.parameters]
            })
        }
        if ClaudeClient.supportsEffort(model) {
            body["output_config"] = ["effort": .string(effort)]
        }
        var betas: [String] = []
        if useRefusalFallback, ClaudeClient.defaultFallbackModels.contains(model) {
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        }
        let json = try await client.createMessage(.object(body), betas: betas)
        return try ClaudeProvider.parseReply(json, requestedModel: model)
    }

    static func attachmentBlocks(_ attachment: Attachment) -> [JSONValue] {
        let b64 = JSONValue.string(attachment.data.base64EncodedString())
        if ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(attachment.mimeType) {
            return [["type": "image", "source": ["type": "base64", "media_type": .string(attachment.mimeType), "data": b64]]]
        }
        if attachment.isPDF {
            return [["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": b64]]]
        }
        if let text = String(data: attachment.data, encoding: .utf8) {
            return [["type": "text", "text": .string("Attached file \"\(attachment.name)\":\n```\n\(text.prefix(200_000))\n```")]]
        }
        return [["type": "text", "text": .string("[Attached file \"\(attachment.name)\" (\(attachment.mimeType)) is not supported]")]]
    }

    /// After a mid-output fallback, blocks of the declined attempt (thinking,
    /// tool_use, ...) before the final `fallback` marker must not be echoed.
    static func sanitize(_ blocks: [JSONValue]) -> [JSONValue] {
        guard let lastFallback = blocks.lastIndex(where: { $0["type"]?.stringValue == "fallback" }) else { return blocks }
        var result: [JSONValue] = []
        for (index, block) in blocks.enumerated() {
            let type = block["type"]?.stringValue ?? ""
            if index < lastFallback {
                if type == "text" { result.append(block) }
            } else if index > lastFallback {
                result.append(block)
            }
        }
        return result
    }

    static func messages(from history: [ChatMessage]) -> [JSONValue] {
        var turns: [(role: String, content: [JSONValue])] = []
        func add(_ role: String, _ content: [JSONValue]) {
            guard !content.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].content.append(contentsOf: content)
            } else {
                turns.append((role: role, content: content))
            }
        }
        func textBlock(_ text: String) -> JSONValue? {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ["type": "text", "text": .string(text)]
        }

        for message in history where !message.isLocalNotice {
            switch message.role {
            case .user:
                var content: [JSONValue] = []
                for part in message.parts {
                    if part.kind == .text, let text = part.text, let block = textBlock(text) {
                        content.append(block)
                    } else if part.kind == .attachment, let attachment = part.attachment {
                        content.append(contentsOf: attachmentBlocks(attachment))
                    }
                }
                add("user", content)

            case .assistant:
                if message.provider == .claude, let raw = message.providerRaw?.arrayValue, !raw.isEmpty {
                    // Replay verbatim (keeps thinking blocks valid).
                    add("assistant", raw)
                    continue
                }
                var content: [JSONValue] = []
                for part in message.parts {
                    if part.kind == .text, let text = part.text, let block = textBlock(text) {
                        content.append(block)
                    } else if let call = part.toolCall {
                        content.append([
                            "type": "tool_use",
                            "id": .string(call.id),
                            "name": .string(call.name),
                            "input": call.arguments.objectValue != nil ? call.arguments : [:]
                        ])
                    }
                }
                add("assistant", content)

            case .tool:
                var content: [JSONValue] = []
                for result in message.toolResults {
                    var inner: [JSONValue] = [["type": "text", "text": .string(result.output.isEmpty ? "(no output)" : result.output)]]
                    for image in result.images { inner.append(contentsOf: attachmentBlocks(image)) }
                    var block: [String: JSONValue] = [
                        "type": "tool_result",
                        "tool_use_id": .string(result.callID),
                        "content": .array(inner)
                    ]
                    if result.isError { block["is_error"] = true }
                    content.append(.object(block))
                }
                add("user", content)
            }
        }
        return turns.map { ["role": .string($0.role), "content": .array($0.content)] }
    }

    static func totalTokens(_ usage: JSONValue?) -> Int? {
        guard let usage else { return nil }
        let keys = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let total = keys.compactMap { usage[$0]?.intValue }.reduce(0, +)
        return total > 0 ? total : nil
    }

    static func parseReply(_ json: JSONValue, requestedModel: String) throws -> LLMReply {
        let stopReason = json["stop_reason"]?.stringValue
        if stopReason == "refusal" {
            let details = json["stop_details"]
            let category = details?["category"]?.stringValue
            let explanation = details?["explanation"]?.stringValue
            let reason = [category.map { "Category: \($0)." }, explanation].compactMap { $0 }.joined(separator: " ")
            throw LLMError.refused(reason)
        }
        let blocks = sanitize(json["content"]?.arrayValue ?? [])
        var parts: [MessagePart] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { parts.append(.text(text)) }
            case "tool_use":
                parts.append(.call(ToolCall(
                    id: block["id"]?.stringValue ?? ToolCall.makeLocalID(),
                    name: block["name"]?.stringValue ?? "",
                    arguments: block["input"] ?? [:]
                )))
            default:
                break
            }
        }
        if parts.isEmpty {
            throw LLMError.emptyResponse(stopReason ?? "no content")
        }
        return LLMReply(
            parts: parts,
            raw: .array(blocks),
            model: json["model"]?.stringValue ?? requestedModel,
            stopReason: stopReason,
            notice: stopReason == "max_tokens" ? "The reply was cut off because it hit the length limit." : nil,
            tokens: ClaudeProvider.totalTokens(json["usage"])
        )
    }
}
