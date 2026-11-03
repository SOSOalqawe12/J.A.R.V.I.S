import Foundation

/// Minimal REST client for the Gemini API (generativelanguage.googleapis.com).
struct GeminiClient {
    let apiKey: String
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private var headers: [String: String] { ["x-goog-api-key": apiKey] }

    static func cleanModelName(_ name: String) -> String {
        name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
    }

    static func errorMessage(_ json: JSONValue) -> String? {
        json["error"]?["message"]?.stringValue
    }

    func generateContent(model: String, body: JSONValue) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.gemini) }
        let name = GeminiClient.cleanModelName(model)
        guard let url = URL(string: "\(GeminiClient.baseURL)/models/\(name):generateContent") else {
            throw LLMError.invalidResponse("bad model name \(name)")
        }
        let request = HTTP.jsonRequest(url: url, headers: headers, body: body)
        return try await HTTP.send(request, errorParser: GeminiClient.errorMessage)
    }

    /// Server-sent-events streaming; calls `onChunk` with each partial response.
    func streamGenerateContent(model: String, body: JSONValue, onChunk: (JSONValue) -> Void) async throws {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.gemini) }
        let name = GeminiClient.cleanModelName(model)
        guard let url = URL(string: "\(GeminiClient.baseURL)/models/\(name):streamGenerateContent?alt=sse") else {
            throw LLMError.invalidResponse("bad model name \(name)")
        }
        let request = HTTP.jsonRequest(url: url, headers: headers, body: body)
        for attempt in 0..<3 {
            let (bytes, response) = try await HTTP.session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64_000 { break }
                }
                let message = (try? JSONValue.parse(data)).flatMap(GeminiClient.errorMessage)
                    ?? String(decoding: data.prefix(500), as: UTF8.self)
                if [429, 500, 503].contains(status), attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                    continue
                }
                throw LLMError.http(status: status, message: message)
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, let json = try? JSONValue.parse(payload) else { continue }
                if let message = GeminiClient.errorMessage(json) { throw LLMError.http(status: 500, message: message) }
                onChunk(json)
            }
            return
        }
    }

    // MARK: Models

    func listModels() async throws -> [GeminiModelInfo] {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.gemini) }
        var models: [GeminiModelInfo] = []
        var pageToken: String?
        for _ in 0..<5 {
            var components = URLComponents(string: "\(GeminiClient.baseURL)/models")!
            var items = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            let request = HTTP.jsonRequest(url: components.url!, method: "GET", headers: headers, body: nil)
            let json = try await HTTP.send(request, errorParser: GeminiClient.errorMessage)
            for model in json["models"]?.arrayValue ?? [] {
                guard let name = model["name"]?.stringValue else { continue }
                let methods = (model["supportedGenerationMethods"]?.arrayValue ?? []).compactMap(\.stringValue)
                models.append(GeminiModelInfo(
                    id: GeminiClient.cleanModelName(name),
                    displayName: model["displayName"]?.stringValue ?? name,
                    methods: methods
                ))
            }
            pageToken = json["nextPageToken"]?.stringValue
            if pageToken == nil || pageToken?.isEmpty == true { break }
        }
        return models
    }

    // MARK: Image generation / editing

    struct GeneratedImage {
        let data: Data
        let mimeType: String
        let caption: String?
    }

    func generateImage(prompt: String, inputs: [Attachment], aspectRatio: String?, model: String) async throws -> GeneratedImage {
        var parts: [JSONValue] = inputs.map(GeminiClient.inlineData)
        parts.append(["text": .string(prompt)])

        func body(withAspect: Bool) -> JSONValue {
            var generation: [String: JSONValue] = ["responseModalities": ["TEXT", "IMAGE"]]
            if withAspect, let aspectRatio, !aspectRatio.isEmpty {
                generation["imageConfig"] = ["aspectRatio": .string(aspectRatio)]
            }
            return [
                "contents": [["role": "user", "parts": .array(parts)]],
                "generationConfig": .object(generation)
            ]
        }

        let json: JSONValue
        do {
            json = try await generateContent(model: model, body: body(withAspect: true))
        } catch LLMError.http(let status, _) where status == 400 && aspectRatio != nil {
            // Some image models don't accept imageConfig – retry without it.
            json = try await generateContent(model: model, body: body(withAspect: false))
        }

        let candidate = json["candidates"]?[0]
        let responseParts = candidate?["content"]?["parts"]?.arrayValue ?? []
        var caption: [String] = []
        for part in responseParts {
            if let inline = part["inlineData"] ?? part["inline_data"],
               let mime = (inline["mimeType"] ?? inline["mime_type"])?.stringValue, mime.hasPrefix("image/"),
               let b64 = inline["data"]?.stringValue, let data = Data(base64Encoded: b64) {
                return GeneratedImage(data: data, mimeType: mime, caption: caption.isEmpty ? nil : caption.joined(separator: "\n"))
            }
            if let text = part["text"]?.stringValue, part["thought"]?.boolValue != true { caption.append(text) }
        }
        let reason = candidate?["finishReason"]?.stringValue
            ?? json["promptFeedback"]?["blockReason"]?.stringValue ?? "no image returned"
        let detail = caption.isEmpty ? reason : "\(reason): \(caption.joined(separator: " "))"
        throw LLMError.emptyResponse("image model returned no image – \(detail)")
    }

    // MARK: Text to speech

    func synthesizeSpeech(text: String, voice: String, style: String?, model: String) async throws -> Data {
        let prompt: String
        if let style, !style.isEmpty { prompt = "\(style): \(text)" } else { prompt = text }
        let body: JSONValue = [
            "contents": [["role": "user", "parts": [["text": .string(prompt)]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(voice)]]]
            ]
        ]
        let json = try await generateContent(model: model, body: body)
        let parts = json["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? []
        for part in parts {
            guard let inline = part["inlineData"] ?? part["inline_data"],
                  let b64 = inline["data"]?.stringValue,
                  let pcm = Data(base64Encoded: b64) else { continue }
            let mime = (inline["mimeType"] ?? inline["mime_type"])?.stringValue ?? ""
            if mime.contains("wav") { return pcm }
            var rate = 24_000
            if let range = mime.range(of: "rate=") {
                let digits = mime[range.upperBound...].prefix { $0.isNumber }
                rate = Int(digits) ?? 24_000
            }
            return WAVEncoder.wav(fromPCM16: pcm, sampleRate: rate, channels: 1)
        }
        throw LLMError.emptyResponse("speech model returned no audio")
    }

    // MARK: Google Search grounding

    func groundedSearch(_ query: String, model: String) async throws -> String {
        let body: JSONValue = [
            "contents": [["role": "user", "parts": [["text": .string(
                "Search the web and answer thoroughly with concrete facts, numbers and dates. Query: \(query)"
            )]]]],
            "tools": [["googleSearch": [:]]]
        ]
        let json = try await generateContent(model: model, body: body)
        let candidate = json["candidates"]?[0]
        let text = (candidate?["content"]?["parts"]?.arrayValue ?? [])
            .filter { $0["thought"]?.boolValue != true }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        var sources: [String] = []
        for chunk in candidate?["groundingMetadata"]?["groundingChunks"]?.arrayValue ?? [] {
            if let uri = chunk["web"]?["uri"]?.stringValue {
                let title = chunk["web"]?["title"]?.stringValue ?? uri
                sources.append("- \(title): \(uri)")
            }
        }
        if text.isEmpty { throw LLMError.emptyResponse("search returned nothing") }
        return sources.isEmpty ? text : text + "\n\nSources:\n" + sources.prefix(8).joined(separator: "\n")
    }

    // MARK: Helpers

    static func inlineData(_ attachment: Attachment) -> JSONValue {
        ["inlineData": ["mimeType": .string(attachment.mimeType), "data": .string(attachment.data.base64EncodedString())]]
    }
}

// MARK: - Model catalog (auto-picks the newest models available to the key)

struct GeminiModelInfo: Hashable, Identifiable {
    let id: String
    let displayName: String
    let methods: [String]

    var supportsGenerateContent: Bool { methods.contains("generateContent") }
}

enum GeminiModelRole {
    case chat, image, tts, live
}

enum GeminiModelPicker {
    static let fallbackChat = "gemini-flash-latest"
    static let fallbackImage = "gemini-2.5-flash-image"
    static let fallbackTTS = "gemini-2.5-flash-preview-tts"
    static let fallbackLive = "gemini-2.5-flash-native-audio-preview-09-2025"

    static func version(of name: String) -> Double {
        for component in name.split(separator: "-").dropFirst() {
            if let value = Double(component) { return value }
        }
        return 0
    }

    static func candidates(_ models: [GeminiModelInfo], for role: GeminiModelRole) -> [GeminiModelInfo] {
        if role == .live {
            return models.filter { $0.methods.contains("bidiGenerateContent") && $0.id.hasPrefix("gemini-") }
        }
        let usable = models.filter { $0.supportsGenerateContent && $0.id.hasPrefix("gemini-") }
        switch role {
        case .chat:
            let excluded = ["image", "tts", "live", "audio", "embedding", "robotics", "computer-use", "native", "exp", "aqa", "learnlm"]
            return usable.filter { model in !excluded.contains { model.id.contains($0) } }
        case .image:
            return usable.filter { $0.id.contains("image") }
        case .tts:
            return usable.filter { $0.id.contains("tts") }
        case .live:
            return []
        }
    }

    static func score(_ name: String, role: GeminiModelRole) -> Double {
        var score = version(of: name) * 10
        let preview = name.contains("preview")
        switch role {
        case .chat:
            if name.contains("flash") { score += 3 }
            if name.contains("lite") { score -= 6 }
            if name.contains("pro") { score -= 1 }
            if !preview { score += 1 }
            if name.hasSuffix("-latest") { score -= 100 }
        case .image:
            if name.contains("flash") { score += 2 }
            if name.contains("lite") { score -= 3 }
            if !preview { score += 3 }
        case .tts:
            if name.contains("flash") { score += 2 }
            if name.contains("lite") { score -= 3 }
            if !preview { score += 3 }
        case .live:
            if name.contains("native-audio") || name.contains("audio") { score += 5 }
            if name.contains("flash") { score += 2 }
            if name.contains("lite") { score -= 3 }
            if name.contains("thinking") { score -= 1 }
            if !preview { score += 1 }
        }
        return score
    }

    static func best(_ models: [GeminiModelInfo], for role: GeminiModelRole) -> String? {
        candidates(models, for: role).max { score($0.id, role: role) < score($1.id, role: role) }?.id
    }

    static func fallback(for role: GeminiModelRole) -> String {
        switch role {
        case .chat: return fallbackChat
        case .image: return fallbackImage
        case .tts: return fallbackTTS
        case .live: return fallbackLive
        }
    }
}

actor GeminiModelCatalog {
    static let shared = GeminiModelCatalog()

    private var cache: [String: [GeminiModelInfo]] = [:]

    func models(apiKey: String, refresh: Bool = false) async -> [GeminiModelInfo] {
        if !refresh, let cached = cache[apiKey] { return cached }
        guard let models = try? await GeminiClient(apiKey: apiKey).listModels(), !models.isEmpty else {
            return cache[apiKey] ?? []
        }
        cache[apiKey] = models
        return models
    }

    /// Returns the user's chosen model, or the best available one for the role.
    func resolve(_ role: GeminiModelRole, preferred: String, apiKey: String) async -> String {
        if !preferred.isEmpty { return preferred }
        let models = await models(apiKey: apiKey)
        return GeminiModelPicker.best(models, for: role) ?? GeminiModelPicker.fallback(for: role)
    }
}

// MARK: - Chat provider with function calling

struct GeminiProvider: LLMProvider {
    let client: GeminiClient
    let model: String
    /// Cheaper model with higher limits, tried automatically when `model` is rate-limited.
    var fallbackModel: String? = nil

    var kind: ProviderKind { .gemini }
    var modelName: String { model }

    func makeBody(_ request: LLMRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "contents": .array(GeminiProvider.contents(from: request.messages, model: model))
        ]
        if !request.system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": .string(request.system)]]]
        }
        if !request.tools.isEmpty {
            body["tools"] = [["functionDeclarations": .array(request.tools.map(GeminiProvider.declaration))]]
        }
        return .object(body)
    }

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        do {
            let json = try await client.generateContent(model: model, body: makeBody(request))
            return try GeminiProvider.parseReply(json, model: model)
        } catch let error as LLMError where error.isRateLimit {
            guard let fallbackModel, fallbackModel != model else { throw error }
            var reply = try await GeminiProvider(client: client, model: fallbackModel).complete(request)
            reply.notice = "\(model) is rate-limited, so \(fallbackModel) answered."
            return reply
        }
    }

    func completeStreaming(_ request: LLMRequest, onPartial: @escaping (String) -> Void) async throws -> LLMReply {
        do {
            var accumulator = GeminiStreamAccumulator()
            try await client.streamGenerateContent(model: model, body: makeBody(request)) { chunk in
                if accumulator.add(chunk) { onPartial(accumulator.visibleText) }
            }
            return try GeminiProvider.parseReply(accumulator.response(model: model), model: model)
        } catch let error as LLMError where error.isRateLimit {
            guard let fallbackModel, fallbackModel != model else { throw error }
            var reply = try await GeminiProvider(client: client, model: fallbackModel).completeStreaming(request, onPartial: onPartial)
            reply.notice = "\(model) is rate-limited, so \(fallbackModel) answered."
            return reply
        }
    }

    static func declaration(_ tool: ToolSpec) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description)
        ]
        // Gemini rejects parameter objects without properties.
        if let properties = tool.parameters["properties"]?.objectValue, !properties.isEmpty {
            dict["parameters"] = tool.parameters
        }
        return .object(dict)
    }

    static func attachmentParts(_ attachment: Attachment) -> [JSONValue] {
        if attachment.isImage || attachment.isPDF || attachment.mimeType.hasPrefix("audio/") || attachment.mimeType.hasPrefix("video/") {
            return [GeminiClient.inlineData(attachment)]
        }
        if let text = String(data: attachment.data, encoding: .utf8) {
            return [["text": .string("Attached file \"\(attachment.name)\":\n```\n\(text.prefix(200_000))\n```")]]
        }
        return [["text": .string("[Attached file \"\(attachment.name)\" (\(attachment.mimeType)) could not be read]")]]
    }

    static func contents(from messages: [ChatMessage], model: String) -> [JSONValue] {
        let requiresSignatures = GeminiModelPicker.version(of: model) >= 3
        // IDs Gemini itself issued (only those may be echoed back as ids).
        var geminiCallIDs = Set<String>()
        for message in messages where message.provider == .gemini {
            for call in message.toolCalls where call.hasProviderID { geminiCallIDs.insert(call.id) }
        }

        var turns: [(role: String, parts: [JSONValue])] = []
        func add(_ role: String, _ parts: [JSONValue]) {
            guard !parts.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].parts.append(contentsOf: parts)
            } else {
                turns.append((role: role, parts: parts))
            }
        }

        for message in messages where !message.isLocalNotice {
            switch message.role {
            case .user:
                var parts: [JSONValue] = []
                for part in message.parts {
                    if part.kind == .text, let text = part.text, !text.isEmpty {
                        parts.append(["text": .string(text)])
                    } else if part.kind == .attachment, let attachment = part.attachment {
                        parts.append(contentsOf: attachmentParts(attachment))
                    }
                }
                add("user", parts)

            case .assistant:
                if message.provider == .gemini, let raw = message.providerRaw?.arrayValue, !raw.isEmpty {
                    add("model", raw)
                    continue
                }
                var parts: [JSONValue] = []
                for part in message.parts {
                    if part.kind == .text, let text = part.text, !text.isEmpty {
                        parts.append(["text": .string(text)])
                    } else if let call = part.toolCall {
                        var functionCall: [String: JSONValue] = [
                            "name": .string(call.name),
                            "args": call.arguments.objectValue != nil ? call.arguments : [:]
                        ]
                        if geminiCallIDs.contains(call.id) { functionCall["id"] = .string(call.id) }
                        var dict: [String: JSONValue] = ["functionCall": .object(functionCall)]
                        if let signature = call.thoughtSignature {
                            dict["thoughtSignature"] = .string(signature)
                        } else if requiresSignatures {
                            // History produced by another provider has no signature.
                            dict["thoughtSignature"] = "skip_thought_signature_validator"
                        }
                        parts.append(.object(dict))
                    }
                }
                add("model", parts)

            case .tool:
                var responses: [JSONValue] = []
                var media: [JSONValue] = []
                for result in message.toolResults {
                    var response: [String: JSONValue] = [
                        "name": .string(result.name),
                        "response": result.isError ? ["error": .string(result.output)] : ["result": .string(result.output)]
                    ]
                    if geminiCallIDs.contains(result.callID) { response["id"] = .string(result.callID) }
                    responses.append(["functionResponse": .object(response)])
                    media.append(contentsOf: result.images.map(GeminiClient.inlineData))
                }
                add("user", responses + media)
            }
        }
        return turns.map { ["role": .string($0.role), "parts": .array($0.parts)] }
    }

    static func parseReply(_ json: JSONValue, model: String) throws -> LLMReply {
        guard let candidate = json["candidates"]?[0] else {
            let reason = json["promptFeedback"]?["blockReason"]?.stringValue ?? "no candidates"
            throw LLMError.refused("Gemini blocked the prompt (\(reason)).")
        }
        let finish = candidate["finishReason"]?.stringValue
        let rawParts = candidate["content"]?["parts"]?.arrayValue ?? []
        var parts: [MessagePart] = []
        for raw in rawParts {
            if raw["thought"]?.boolValue == true { continue }
            let signature = raw["thoughtSignature"]?.stringValue
            if let functionCall = raw["functionCall"] {
                let call = ToolCall(
                    id: functionCall["id"]?.stringValue ?? ToolCall.makeLocalID(),
                    name: functionCall["name"]?.stringValue ?? "",
                    arguments: functionCall["args"] ?? [:],
                    thoughtSignature: signature
                )
                parts.append(.call(call))
            } else if let text = raw["text"]?.stringValue, !text.isEmpty {
                parts.append(.text(text, signature: signature))
            }
        }
        if parts.isEmpty {
            switch finish {
            case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY":
                throw LLMError.refused("Gemini stopped for: \(finish ?? "").")
            case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL":
                throw LLMError.emptyResponse("the model produced an invalid tool call – try rephrasing")
            default:
                throw LLMError.emptyResponse(finish ?? "unknown reason")
            }
        }
        return LLMReply(
            parts: parts,
            raw: .array(rawParts),
            model: json["modelVersion"]?.stringValue ?? model,
            stopReason: finish,
            notice: finish == "MAX_TOKENS" ? "The reply was cut off because it hit the length limit." : nil,
            tokens: json["usageMetadata"]?["totalTokenCount"]?.intValue
        )
    }
}

// MARK: - Streaming accumulator

/// Merges streamed Gemini chunks into one response (text deltas are joined,
/// function calls and thought signatures are kept intact for replay).
struct GeminiStreamAccumulator {
    private(set) var parts: [JSONValue] = []
    private(set) var finishReason: String?
    private(set) var modelVersion: String?
    private(set) var blockReason: String?
    private(set) var usage: JSONValue?

    var visibleText: String {
        parts.filter { $0["thought"]?.boolValue != true && $0["functionCall"] == nil }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }

    private static func isPlainText(_ part: JSONValue) -> Bool {
        part["text"] != nil && part["functionCall"] == nil && part["thought"]?.boolValue != true
    }

    /// Returns true when the visible text changed.
    @discardableResult
    mutating func add(_ chunk: JSONValue) -> Bool {
        if let version = chunk["modelVersion"]?.stringValue { modelVersion = version }
        if let reason = chunk["promptFeedback"]?["blockReason"]?.stringValue { blockReason = reason }
        if let metadata = chunk["usageMetadata"] { usage = metadata }
        guard let candidate = chunk["candidates"]?[0] else { return false }
        if let finish = candidate["finishReason"]?.stringValue { finishReason = finish }
        var changed = false
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            let text = part["text"]?.stringValue
            if GeminiStreamAccumulator.isPlainText(part), let text,
               let last = parts.indices.last, GeminiStreamAccumulator.isPlainText(parts[last]),
               parts[last]["thoughtSignature"] == nil {
                var merged = parts[last].objectValue ?? [:]
                merged["text"] = .string((merged["text"]?.stringValue ?? "") + text)
                if let signature = part["thoughtSignature"] { merged["thoughtSignature"] = signature }
                parts[last] = .object(merged)
                if !text.isEmpty { changed = true }
            } else {
                parts.append(part)
                if GeminiStreamAccumulator.isPlainText(part), let text, !text.isEmpty { changed = true }
            }
        }
        return changed
    }

    func response(model: String) -> JSONValue {
        var root: [String: JSONValue] = ["modelVersion": .string(modelVersion ?? model)]
        if !parts.isEmpty || finishReason != nil {
            var candidate: [String: JSONValue] = ["content": ["role": "model", "parts": .array(parts)]]
            if let finishReason { candidate["finishReason"] = .string(finishReason) }
            root["candidates"] = [.object(candidate)]
        }
        if let blockReason { root["promptFeedback"] = ["blockReason": .string(blockReason)] }
        if let usage { root["usageMetadata"] = usage }
        return .object(root)
    }
}

// MARK: - WAV

enum WAVEncoder {
    static func wav(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteRate = sampleRate * channels * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(channels * 2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
