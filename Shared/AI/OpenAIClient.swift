import Foundation
import PDFKit

/// Client for OpenAI and any OpenAI-compatible server
/// (Ollama, LM Studio, llama.cpp, vLLM, Jan, OpenRouter, Groq, DeepSeek, Mistral, xAI…).
struct OpenAICompatibleClient {
    static let openAIBaseURL = "https://api.openai.com/v1"

    let baseURL: String
    let apiKey: String

    struct Preset: Identifiable, Hashable {
        let name: String
        let baseURL: String
        let note: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Ollama", baseURL: "http://localhost:11434/v1", note: "ollama serve · from iPhone use your Mac's IP and OLLAMA_HOST=0.0.0.0"),
        Preset(name: "LM Studio", baseURL: "http://localhost:1234/v1", note: "Developer tab › Start server"),
        Preset(name: "llama.cpp", baseURL: "http://localhost:8080/v1", note: "llama-server -m model.gguf"),
        Preset(name: "Jan", baseURL: "http://localhost:1337/v1", note: "Settings › Local API server"),
        Preset(name: "vLLM", baseURL: "http://localhost:8000/v1", note: "vllm serve <model>"),
        Preset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", note: "API key from openrouter.ai"),
        Preset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", note: "API key from console.groq.com"),
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", note: "API key from platform.deepseek.com"),
        Preset(name: "Mistral", baseURL: "https://api.mistral.ai/v1", note: "API key from console.mistral.ai"),
        Preset(name: "xAI", baseURL: "https://api.x.ai/v1", note: "API key from console.x.ai"),
        Preset(name: "Together", baseURL: "https://api.together.xyz/v1", note: "API key from together.ai")
    ]

    private var root: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: root + path), url.scheme != nil else {
            throw LLMError.unavailable("The server address \"\(baseURL)\" isn't a valid URL (e.g. http://localhost:11434/v1).")
        }
        return url
    }

    private var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    static func errorMessage(_ json: JSONValue) -> String? {
        json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue ?? json["detail"]?.stringValue ?? json["message"]?.stringValue
    }

    func chat(_ body: JSONValue) async throws -> JSONValue {
        let request = HTTP.jsonRequest(url: try url("/chat/completions"), headers: headers, body: body)
        return try await HTTP.send(request, errorParser: OpenAICompatibleClient.errorMessage)
    }

    func streamChat(_ body: JSONValue, onChunk: (JSONValue) -> Void) async throws {
        let request = HTTP.jsonRequest(url: try url("/chat/completions"), headers: headers, body: body)
        let (bytes, response) = try await HTTP.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            let message = (try? JSONValue.parse(data)).flatMap(OpenAICompatibleClient.errorMessage)
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw LLMError.http(status: status, message: message)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard !payload.isEmpty, let json = try? JSONValue.parse(payload) else { continue }
            if let message = OpenAICompatibleClient.errorMessage(json), json["choices"] == nil {
                throw LLMError.http(status: 500, message: message)
            }
            onChunk(json)
        }
    }

    func listModels(timeout: TimeInterval = 8) async throws -> [String] {
        var request = HTTP.jsonRequest(url: try url("/models"), method: "GET", headers: headers, body: nil)
        request.timeoutInterval = timeout
        let (data, response) = try await HTTP.quickSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONValue.parse(data)) ?? .null
        guard (200..<300).contains(status) else {
            throw LLMError.http(status: status, message: OpenAICompatibleClient.errorMessage(json) ?? "HTTP \(status)")
        }
        let ids = (json["data"]?.arrayValue ?? json["models"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue ?? $0["name"]?.stringValue }
        return ids.sorted()
    }

    // MARK: Images & speech (OpenAI)

    static func imageSize(for aspectRatio: String?) -> String {
        switch aspectRatio {
        case "9:16", "3:4", "2:3": return "1024x1536"
        case "16:9", "4:3", "3:2", "21:9": return "1536x1024"
        default: return "1024x1024"
        }
    }

    func generateImage(prompt: String, aspectRatio: String?, model: String) async throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "prompt": .string(prompt),
            "n": 1,
            "size": .string(OpenAICompatibleClient.imageSize(for: aspectRatio))
        ]
        if model.hasPrefix("dall-e") {
            body["response_format"] = "b64_json"
            body["size"] = "1024x1024"
        }
        let request = HTTP.jsonRequest(url: try url("/images/generations"), headers: headers, body: .object(body))
        let json = try await HTTP.send(request, errorParser: OpenAICompatibleClient.errorMessage)
        guard let b64 = json["data"]?[0]?["b64_json"]?.stringValue, let data = Data(base64Encoded: b64) else {
            throw LLMError.emptyResponse("no image returned")
        }
        return data
    }

    func editImage(_ image: Attachment, prompt: String, model: String) async throws -> Data {
        let boundary = "JARVIS-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("prompt", prompt)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(image.name)\"\r\nContent-Type: \(image.mimeType)\r\n\r\n".utf8))
        body.append(image.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: try url("/images/edits"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let json = try await HTTP.send(request, errorParser: OpenAICompatibleClient.errorMessage)
        guard let b64 = json["data"]?[0]?["b64_json"]?.stringValue, let data = Data(base64Encoded: b64) else {
            throw LLMError.emptyResponse("no edited image returned")
        }
        return data
    }

    /// Returns MP3 audio.
    func speech(_ text: String, voice: String, model: String = "gpt-4o-mini-tts") async throws -> Data {
        let body: JSONValue = ["model": .string(model), "voice": .string(voice), "input": .string(text), "response_format": "mp3"]
        let request = HTTP.jsonRequest(url: try url("/audio/speech"), headers: headers, body: body)
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONValue.parse(data)).flatMap(OpenAICompatibleClient.errorMessage) ?? "HTTP \(status)"
            throw LLMError.http(status: status, message: message)
        }
        return data
    }

    static let voices = ["onyx", "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "sage", "shimmer", "verse"]

    /// Picks a sensible default chat model from an OpenAI /models list.
    static func bestOpenAIModel(_ ids: [String]) -> String? {
        let excluded = ["audio", "realtime", "transcribe", "tts", "image", "embedding", "moderation", "search", "instruct", "dall-e", "whisper", "davinci", "babbage", "codex"]
        let chat = ids.filter { id in id.hasPrefix("gpt-") && !excluded.contains { id.contains($0) } }
        func score(_ id: String) -> Double {
            let numbers = id.dropFirst(4).split(whereSeparator: { !"0123456789.".contains($0) })
            var value = Double(numbers.first ?? "") ?? 0
            if id.contains("mini") { value -= 0.3 }
            if id.contains("nano") { value -= 0.6 }
            if id.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) != nil { value -= 0.05 }
            return value
        }
        return chat.max { score($0) < score($1) }
    }
}

// MARK: - Chat provider

struct OpenAICompatibleProvider: LLMProvider {
    enum ToolMode: String {
        case native, prompted, off
    }

    let kind: ProviderKind
    let client: OpenAICompatibleClient
    let model: String
    let toolMode: ToolMode

    var modelName: String { model }

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        try await run(request, onPartial: nil)
    }

    func completeStreaming(_ request: LLMRequest, onPartial: @escaping (String) -> Void) async throws -> LLMReply {
        try await run(request, onPartial: onPartial)
    }

    private func run(_ request: LLMRequest, onPartial: ((String) -> Void)?) async throws -> LLMReply {
        let mode: ToolMode = request.tools.isEmpty ? .off : toolMode
        do {
            return try await perform(request, mode: mode, onPartial: onPartial)
        } catch LLMError.http(let status, let message) where mode == .native && OpenAICompatibleProvider.isToolSupportError(status, message) {
            // The model can't do native function calling – fall back to prompted tools.
            var reply = try await perform(request, mode: .prompted, onPartial: onPartial)
            reply.notice = "This model doesn't support native tool calling, so JARVIS described the tools in the prompt instead."
            return reply
        }
    }

    static func isToolSupportError(_ status: Int, _ message: String) -> Bool {
        let lower = message.lowercased()
        return (400..<500).contains(status) && lower.contains("tool") && (lower.contains("support") || lower.contains("not allowed") || lower.contains("unknown"))
    }

    private func perform(_ request: LLMRequest, mode: ToolMode, onPartial: ((String) -> Void)?) async throws -> LLMReply {
        var system = request.system
        if mode == .prompted { system += "\n\n" + PromptedTools.instructions(for: request.tools) }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(OpenAICompatibleProvider.messages(from: request.messages, system: system, mode: mode))
        ]
        if mode == .native {
            body["tools"] = .array(request.tools.map { tool -> JSONValue in
                ["type": "function", "function": ["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters]]
            })
        }
        let message: JSONValue
        let finish: String?
        let tokens: Int?
        if let onPartial {
            body["stream"] = true
            if kind == .openai { body["stream_options"] = ["include_usage": true] }
            var accumulator = OpenAIStreamAccumulator()
            try await client.streamChat(.object(body)) { chunk in
                if accumulator.add(chunk) {
                    onPartial(PromptedTools.stripReasoning(PromptedTools.extract(accumulator.content).text))
                }
            }
            message = accumulator.message
            finish = accumulator.finishReason
            tokens = accumulator.totalTokens
        } else {
            let json = try await client.chat(.object(body))
            message = json["choices"]?[0]?["message"] ?? [:]
            finish = json["choices"]?[0]?["finish_reason"]?.stringValue
            tokens = json["usage"]?["total_tokens"]?.intValue
        }
        var reply = try OpenAICompatibleProvider.parse(message: message, finishReason: finish, model: model, prompted: mode == .prompted)
        reply.tokens = tokens
        return reply
    }

    static func textContent(_ value: JSONValue?) -> String {
        if let string = value?.stringValue { return string }
        return (value?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
    }

    static func parse(message: JSONValue, finishReason: String?, model: String, prompted: Bool) throws -> LLMReply {
        var text = PromptedTools.stripReasoning(textContent(message["content"]))
        var calls: [ToolCall] = []
        for call in message["tool_calls"]?.arrayValue ?? [] {
            let function = call["function"]
            let rawArguments = function?["arguments"]
            var arguments: JSONValue = [:]
            if let string = rawArguments?.stringValue {
                arguments = (try? JSONValue.parse(string.isEmpty ? "{}" : string)) ?? ["_unparsed": .string(string)]
            } else if let object = rawArguments, object.objectValue != nil {
                arguments = object
            }
            let rawID = call["id"]?.stringValue ?? ""
            calls.append(ToolCall(
                id: rawID.isEmpty ? ToolCall.makeLocalID() : rawID,
                name: function?["name"]?.stringValue ?? "",
                arguments: arguments
            ))
        }
        if prompted || calls.isEmpty {
            let extracted = PromptedTools.extract(text)
            text = extracted.text
            calls.append(contentsOf: extracted.calls)
        }
        var parts: [MessagePart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        parts.append(contentsOf: calls.map { .call($0) })
        if parts.isEmpty {
            if finishReason == "content_filter" { throw LLMError.refused("The response was filtered.") }
            throw LLMError.emptyResponse(finishReason ?? "no content")
        }
        return LLMReply(
            parts: parts,
            raw: message,
            model: model,
            stopReason: finishReason,
            notice: finishReason == "length" ? "The reply was cut off because it hit the length limit." : nil
        )
    }

    // MARK: Message conversion

    static func attachmentText(_ attachment: Attachment) -> String {
        if attachment.isPDF, let document = PDFDocument(data: attachment.data) {
            return "Attached PDF \"\(attachment.name)\" (\(document.pageCount) pages):\n\(String((document.string ?? "").prefix(100_000)))"
        }
        if let text = String(data: attachment.data, encoding: .utf8) {
            return "Attached file \"\(attachment.name)\":\n```\n\(text.prefix(100_000))\n```"
        }
        return "[Attached file \"\(attachment.name)\" (\(attachment.mimeType)) can't be read by this model]"
    }

    static func imagePart(_ attachment: Attachment) -> JSONValue {
        ["type": "image_url", "image_url": ["url": .string("data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())")]]
    }

    static func userMessage(texts: [String], images: [Attachment]) -> JSONValue? {
        let text = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        if images.isEmpty {
            return text.isEmpty ? nil : ["role": "user", "content": .string(text)]
        }
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        content.append(contentsOf: images.map(imagePart))
        return ["role": "user", "content": .array(content)]
    }

    static func messages(from history: [ChatMessage], system: String, mode: ToolMode) -> [JSONValue] {
        var output: [JSONValue] = []
        if !system.isEmpty { output.append(["role": "system", "content": .string(system)]) }
        for message in history where !message.isLocalNotice {
            switch message.role {
            case .user:
                var texts = message.parts.filter { $0.kind == .text }.compactMap(\.text)
                var images: [Attachment] = []
                for attachment in message.attachments {
                    if attachment.isImage { images.append(attachment) } else { texts.append(attachmentText(attachment)) }
                }
                if let user = userMessage(texts: texts, images: images) { output.append(user) }

            case .assistant:
                let text = message.visibleText
                let calls = message.toolCalls
                if mode == .native {
                    guard !text.isEmpty || !calls.isEmpty else { continue }
                    var entry: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
                    if !calls.isEmpty {
                        entry["tool_calls"] = .array(calls.map { call -> JSONValue in
                            ["id": .string(call.id), "type": "function",
                             "function": ["name": .string(call.name), "arguments": .string(call.arguments.jsonString())]]
                        })
                    }
                    output.append(.object(entry))
                } else {
                    let rendered = ([text] + calls.map(PromptedTools.render)).filter { !$0.isEmpty }.joined(separator: "\n")
                    if !rendered.isEmpty { output.append(["role": "assistant", "content": .string(rendered)]) }
                }

            case .tool:
                let results = message.toolResults
                let images = results.flatMap(\.images)
                if mode == .native {
                    for result in results {
                        output.append([
                            "role": "tool",
                            "tool_call_id": .string(result.callID),
                            "content": .string((result.isError ? "ERROR: " : "") + (result.output.isEmpty ? "(no output)" : result.output))
                        ])
                    }
                    if let extra = userMessage(texts: images.isEmpty ? [] : ["Images returned by the tools above:"], images: images) {
                        output.append(extra)
                    }
                } else {
                    let texts = results.map(PromptedTools.render)
                    if let user = userMessage(texts: texts, images: images) { output.append(user) }
                }
            }
        }
        return output
    }
}

/// Merges OpenAI-style streaming deltas into a final assistant message.
struct OpenAIStreamAccumulator {
    private(set) var content = ""
    private(set) var finishReason: String?
    private(set) var totalTokens: Int?
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    /// Returns true when the visible content changed.
    @discardableResult
    mutating func add(_ chunk: JSONValue) -> Bool {
        if let tokens = chunk["usage"]?["total_tokens"]?.intValue { totalTokens = tokens }
        guard let choice = chunk["choices"]?[0] else { return false }
        if let finish = choice["finish_reason"]?.stringValue { finishReason = finish }
        let delta = choice["delta"] ?? choice["message"] ?? [:]
        var changed = false
        let piece = OpenAICompatibleProvider.textContent(delta["content"])
        if !piece.isEmpty {
            content += piece
            changed = true
        }
        for (position, call) in (delta["tool_calls"]?.arrayValue ?? []).enumerated() {
            let index = call["index"]?.intValue ?? position
            var entry = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"]?.stringValue, !id.isEmpty { entry.id = id }
            if let name = call["function"]?["name"]?.stringValue, !name.isEmpty { entry.name = name }
            if let arguments = call["function"]?["arguments"] {
                entry.arguments += arguments.stringValue ?? arguments.jsonString()
            }
            calls[index] = entry
        }
        return changed
    }

    var message: JSONValue {
        var object: [String: JSONValue] = ["role": "assistant", "content": .string(content)]
        if !calls.isEmpty {
            object["tool_calls"] = .array(calls.keys.sorted().compactMap { key -> JSONValue? in
                guard let call = calls[key] else { return nil }
                return ["id": .string(call.id), "type": "function",
                        "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
            })
        }
        return .object(object)
    }
}

/// Finds OpenAI-compatible servers running on common local ports.
enum LocalServerDetector {
    struct Found: Identifiable, Hashable {
        let name: String
        let baseURL: String
        let models: [String]
        var id: String { baseURL }
    }

    static let ports: [(Int, String)] = [(11434, "Ollama"), (1234, "LM Studio"), (8080, "llama.cpp"), (1337, "Jan"), (8000, "vLLM"), (5001, "KoboldCpp"), (4891, "GPT4All")]

    static func scan(hosts: [String]) async -> [Found] {
        await withTaskGroup(of: Found?.self) { group in
            for host in Set(hosts) {
                for (port, name) in ports {
                    group.addTask {
                        let base = "http://\(host):\(port)/v1"
                        guard let models = try? await OpenAICompatibleClient(baseURL: base, apiKey: "").listModels(timeout: 2) else { return nil }
                        return Found(name: name, baseURL: base, models: models)
                    }
                }
            }
            var found: [Found] = []
            for await result in group { if let result { found.append(result) } }
            return found.sorted { $0.baseURL < $1.baseURL }
        }
    }

    static func host(of baseURL: String) -> String? {
        URL(string: baseURL)?.host
    }
}
