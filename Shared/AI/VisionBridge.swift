import Foundation
import Vision

/// Lets text-only brains (DeepSeek, many local models, the on-device model)
/// "see": images and camera frames are turned into detailed descriptions –
/// by Gemini or OpenAI when a key is available, otherwise on-device with
/// Apple's Vision framework (objects, scene, text, people, animals, codes).
enum VisionBridge {
    /// Best guess whether a model accepts images directly.
    static func supportsImages(model: String, kind: ProviderKind) -> Bool {
        let id = model.lowercased()
        if id.contains("deepseek") { return id.contains("vl") }
        switch kind {
        case .gemini, .claude, .openai: return true
        case .apple, .claudeCode, .deepseek: return false
        case .local: break
        }
        let hints = ["vision", "llava", "bakllava", "-vl", "vl-", "vl:", "vl2", "gemma3", "gemma-3", "minicpm-v", "moondream",
                     "pixtral", "llama-4", "llama4", "llama3.2-vision", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini",
                     "grok-4", "grok-2-vision", "mistral-small", "mistral-medium", "qwen2.5vl", "qwen3-vl", "internvl",
                     "glm-4v", "glm-4.5v", "multimodal", "phi-4-mm", "kimi-vl", "omni"]
        return hints.contains { id.contains($0) }
    }

    /// Replaces images in the conversation with text descriptions.
    static func textOnly(_ messages: [ChatMessage], settings: AppSettings) async -> [ChatMessage] {
        var output: [ChatMessage] = []
        for message in messages {
            var copy = message
            var parts: [MessagePart] = []
            for part in message.parts {
                if part.kind == .attachment, let attachment = part.attachment, attachment.isImage {
                    let description = await describe(attachment, settings: settings)
                    parts.append(.text("[Image \"\(attachment.name)\" – described for you because you can't see images directly: \(description)]"))
                } else if part.kind == .toolResult, var result = part.toolResult, !result.images.isEmpty {
                    for image in result.images {
                        let description = await describe(image, settings: settings)
                        result.output += "\n[Image from the tool – description: \(description)]"
                    }
                    result.images = []
                    parts.append(.result(result))
                } else {
                    parts.append(part)
                }
            }
            copy.parts = parts
            output.append(copy)
        }
        return output
    }

    static func containsImages(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            message.attachments.contains(where: \.isImage) || message.toolResults.contains { !$0.images.isEmpty }
        }
    }

    static func describe(_ attachment: Attachment, settings: AppSettings) async -> String {
        let key = attachment.id.uuidString
        if let cached = await DescriptionCache.shared.get(key) { return cached }
        var description: String?
        let prompt = """
        Describe this image in rich, factual detail for an assistant that cannot see it: the setting, every notable \
        object and person (what they're doing), colours, any text exactly as written, brands, screens or documents, \
        and anything unusual. Be concise but complete.
        """
        if settings.hasGeminiKey {
            let model = await GeminiModelCatalog.shared.resolve(.chat, preferred: settings.geminiChatModel, apiKey: settings.geminiAPIKey)
            let body: JSONValue = ["contents": [["role": "user", "parts": [GeminiClient.inlineData(attachment), ["text": .string(prompt)]]]]]
            if let json = try? await GeminiClient(apiKey: settings.geminiAPIKey).generateContent(model: model, body: body),
               let reply = try? GeminiProvider.parseReply(json, model: model) {
                description = reply.parts.compactMap(\.text).joined()
            }
        }
        if description == nil, settings.hasOpenAIKey {
            let client = OpenAICompatibleClient(baseURL: OpenAICompatibleClient.openAIBaseURL, apiKey: settings.openAIAPIKey)
            let model = settings.openAIModel.isEmpty ? await OpenAIModelCatalog.shared.bestModel(client: client) : settings.openAIModel
            let body: JSONValue = [
                "model": .string(model),
                "messages": [["role": "user", "content": [["type": "text", "text": .string(prompt)], OpenAICompatibleProvider.imagePart(attachment)]]]
            ]
            if let json = try? await client.chat(body) {
                description = OpenAICompatibleProvider.textContent(json["choices"]?[0]?["message"]?["content"])
            }
        }
        let result = (description?.isEmpty == false ? description : nil) ?? onDevice(attachment.data)
        await DescriptionCache.shared.set(key, result)
        return result
    }

    /// Free, offline description using Apple's Vision framework.
    static func onDevice(_ data: Data) -> String {
        guard let image = ImageCoder.thumbnail(from: data, maxPixel: 2000) else { return "the image couldn't be read" }
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.automaticallyDetectsLanguage = true
        let people = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        let codes = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify, text, people, faces, animals, codes])

        var lines = ["on-device analysis (\(image.width)×\(image.height))"]
        let labels = (classify.results ?? [])
            .filter { $0.confidence > 0.25 }
            .prefix(12)
            .map { "\($0.identifier.replacingOccurrences(of: "_", with: " ")) \(Int($0.confidence * 100))%" }
        if !labels.isEmpty { lines.append("scene & objects: " + labels.joined(separator: ", ")) }
        let personCount = max(people.results?.count ?? 0, faces.results?.count ?? 0)
        if personCount > 0 { lines.append("people visible: \(personCount)") }
        let animalNames = (animals.results ?? []).compactMap { $0.labels.first?.identifier }
        if !animalNames.isEmpty { lines.append("animals: " + animalNames.joined(separator: ", ")) }
        let words = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        if !words.isEmpty {
            let joined = String(words.joined(separator: " / ").prefix(1500))
            lines.append("text visible: \"\(joined)\"")
        }
        let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
        if !payloads.isEmpty { lines.append("barcodes/QR: " + payloads.joined(separator: ", ")) }
        if lines.count == 1 { lines.append("nothing clearly recognisable") }
        return lines.joined(separator: "; ")
    }
}

/// Avoids describing the same image again on every turn.
actor DescriptionCache {
    static let shared = DescriptionCache()
    private var store: [String: String] = [:]

    func get(_ key: String) -> String? { store[key] }

    func set(_ key: String, _ value: String) {
        if store.count > 200 { store.removeAll() }
        store[key] = value
    }
}
