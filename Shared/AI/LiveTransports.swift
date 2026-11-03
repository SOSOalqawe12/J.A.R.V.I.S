import Foundation

/// Events a realtime voice backend can produce, independent of the provider.
enum LiveEvent {
    case ready
    case audio(Data)
    case userTranscript(String)
    case modelTranscript(String)
    case userStartedSpeaking
    case interrupted
    case turnComplete
    case toolCalls([LiveToolCall])
    case resumptionHandle(String)
    case goAway
    case error(String)
}

struct LiveToolCall {
    let id: String
    let name: String
    let arguments: JSONValue
}

struct LiveToolResult {
    let call: LiveToolCall
    let output: String
    let isError: Bool
}

enum LiveEngineKind: String, CaseIterable, Identifiable {
    case gemini, openai, classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Gemini Live"
        case .openai: return "OpenAI Realtime"
        case .classic: return "Classic (any brain)"
        }
    }

    /// Picks the engine from the setting and the keys the user has.
    @MainActor
    static func resolve(_ settings: AppSettings) -> LiveEngineKind {
        switch settings.liveEngine {
        case "gemini": return settings.hasGeminiKey ? .gemini : .classic
        case "openai": return settings.hasOpenAIKey ? .openai : .classic
        case "classic": return .classic
        default:
            // Automatic: talk to the brain you picked.
            guard settings.liveVoiceEnabled else { return .classic }
            switch settings.provider {
            case .gemini: return settings.hasGeminiKey ? .gemini : .classic
            case .openai: return settings.hasOpenAIKey ? .openai : .classic
            default: return .classic
            }
        }
    }
}

/// Speaks one provider's realtime protocol.
protocol LiveTransport: AnyObject {
    var micSampleRate: Double { get }
    /// Gemini takes a steady trickle of frames; OpenAI gets one when the user starts talking.
    var streamsFramesContinuously: Bool { get }
    var supportsResumption: Bool { get }
    func connectRequest() throws -> URLRequest
    func setupMessages(system: String, tools: [ToolSpec], resumeHandle: String?, minimal: Bool) -> [JSONValue]
    func audioMessage(_ pcm: Data) -> JSONValue
    func frameMessages(_ jpeg: Data) -> [JSONValue]
    func textMessages(_ text: String) -> [JSONValue]
    func toolResultMessages(_ results: [LiveToolResult]) -> [JSONValue]
    func parse(_ json: JSONValue) -> [LiveEvent]
}

// MARK: - Gemini Live

final class GeminiLiveTransport: LiveTransport {
    static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    let apiKey: String
    let model: String
    let voice: String

    init(apiKey: String, model: String, voice: String) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
    }

    var micSampleRate: Double { 16_000 }
    var streamsFramesContinuously: Bool { true }
    var supportsResumption: Bool { true }

    func connectRequest() throws -> URLRequest {
        var components = URLComponents(string: GeminiLiveTransport.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw LLMError.invalidResponse("Bad Live API URL") }
        return URLRequest(url: url)
    }

    func setupMessages(system: String, tools: [ToolSpec], resumeHandle: String?, minimal: Bool) -> [JSONValue] {
        var generation: [String: JSONValue] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(voice)]]]
        ]
        var setup: [String: JSONValue] = [
            "model": .string("models/" + model),
            "systemInstruction": ["parts": [["text": .string(system)]]],
            "tools": [["functionDeclarations": .array(tools.map(GeminiProvider.declaration))]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:]
        ]
        if !minimal {
            // 64 tokens per camera frame instead of ~258–516: far longer video calls.
            generation["mediaResolution"] = "MEDIA_RESOLUTION_LOW"
            // Lifts the ~2 min (video) / ~15 min (audio) session caps.
            setup["contextWindowCompression"] = ["slidingWindow": [:]]
            // Lets us reconnect seamlessly when the server rotates the connection.
            if let resumeHandle {
                setup["sessionResumption"] = ["handle": .string(resumeHandle)]
            } else {
                setup["sessionResumption"] = [:]
            }
        }
        setup["generationConfig"] = .object(generation)
        return [["setup": .object(setup)]]
    }

    func audioMessage(_ pcm: Data) -> JSONValue {
        ["realtimeInput": ["audio": ["data": .string(pcm.base64EncodedString()), "mimeType": "audio/pcm;rate=16000"]]]
    }

    func frameMessages(_ jpeg: Data) -> [JSONValue] {
        [["realtimeInput": ["video": ["data": .string(jpeg.base64EncodedString()), "mimeType": "image/jpeg"]]]]
    }

    func textMessages(_ text: String) -> [JSONValue] {
        [["clientContent": ["turns": [["role": "user", "parts": [["text": .string(text)]]]], "turnComplete": true]]]
    }

    func toolResultMessages(_ results: [LiveToolResult]) -> [JSONValue] {
        let responses = results.map { result -> JSONValue in
            var entry: [String: JSONValue] = [
                "name": .string(result.call.name),
                "response": result.isError ? ["error": .string(result.output)] : ["result": .string(result.output)]
            ]
            if !result.call.id.isEmpty { entry["id"] = .string(result.call.id) }
            return .object(entry)
        }
        return [["toolResponse": ["functionResponses": .array(responses)]]]
    }

    func parse(_ json: JSONValue) -> [LiveEvent] {
        var events: [LiveEvent] = []
        if json["setupComplete"] != nil { events.append(.ready) }
        if let content = json["serverContent"] {
            if content["interrupted"]?.boolValue == true { events.append(.interrupted) }
            if let text = content["inputTranscription"]?["text"]?.stringValue, !text.isEmpty { events.append(.userTranscript(text)) }
            if let text = content["outputTranscription"]?["text"]?.stringValue, !text.isEmpty { events.append(.modelTranscript(text)) }
            for part in content["modelTurn"]?["parts"]?.arrayValue ?? [] {
                if let b64 = part["inlineData"]?["data"]?.stringValue, let pcm = Data(base64Encoded: b64) {
                    events.append(.audio(pcm))
                }
            }
            if content["turnComplete"]?.boolValue == true { events.append(.turnComplete) }
        }
        if let calls = json["toolCall"]?["functionCalls"]?.arrayValue {
            events.append(.toolCalls(calls.map {
                LiveToolCall(id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "", arguments: $0["args"] ?? [:])
            }))
        }
        if let update = json["sessionResumptionUpdate"], update["resumable"]?.boolValue != false,
           let handle = update["newHandle"]?.stringValue, !handle.isEmpty {
            events.append(.resumptionHandle(handle))
        }
        if json["goAway"] != nil { events.append(.goAway) }
        if let message = json["error"]?["message"]?.stringValue { events.append(.error(message)) }
        return events
    }
}

// MARK: - OpenAI Realtime

final class OpenAIRealtimeTransport: LiveTransport {
    let apiKey: String
    let model: String
    let voice: String

    init(apiKey: String, model: String, voice: String) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
    }

    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    var micSampleRate: Double { 24_000 }
    var streamsFramesContinuously: Bool { false }
    var supportsResumption: Bool { false }

    func connectRequest() throws -> URLRequest {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw LLMError.invalidResponse("Bad Realtime URL") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func setupMessages(system: String, tools: [ToolSpec], resumeHandle: String?, minimal: Bool) -> [JSONValue] {
        let toolList = tools.map { tool -> JSONValue in
            ["type": "function", "name": .string(tool.name), "description": .string(String(tool.description.prefix(1000))), "parameters": tool.parameters]
        }
        var input: [String: JSONValue] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "turn_detection": ["type": "semantic_vad"]
        ]
        if !minimal { input["transcription"] = ["model": "gpt-4o-mini-transcribe"] }
        let session: JSONValue = [
            "type": "realtime",
            "instructions": .string(system),
            "output_modalities": ["audio"],
            "audio": [
                "input": .object(input),
                "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": .string(voice)]
            ],
            "tools": .array(toolList),
            "tool_choice": "auto"
        ]
        return [["type": "session.update", "session": session]]
    }

    func audioMessage(_ pcm: Data) -> JSONValue {
        ["type": "input_audio_buffer.append", "audio": .string(pcm.base64EncodedString())]
    }

    func frameMessages(_ jpeg: Data) -> [JSONValue] {
        [[
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_image", "image_url": .string("data:image/jpeg;base64,\(jpeg.base64EncodedString())")]]
            ]
        ]]
    }

    func textMessages(_ text: String) -> [JSONValue] {
        [
            ["type": "conversation.item.create",
             "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(text)]]]],
            ["type": "response.create"]
        ]
    }

    func toolResultMessages(_ results: [LiveToolResult]) -> [JSONValue] {
        var messages: [JSONValue] = results.map { result in
            ["type": "conversation.item.create",
             "item": ["type": "function_call_output", "call_id": .string(result.call.id),
                      "output": .string(result.isError ? "ERROR: \(result.output)" : result.output)]]
        }
        messages.append(["type": "response.create"])
        return messages
    }

    func parse(_ json: JSONValue) -> [LiveEvent] {
        guard let type = json["type"]?.stringValue else { return [] }
        switch type {
        case "session.updated":
            return [.ready]
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = json["delta"]?.stringValue, let pcm = Data(base64Encoded: b64) { return [.audio(pcm)] }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let text = json["delta"]?.stringValue { return [.modelTranscript(text)] }
        case "conversation.item.input_audio_transcription.completed":
            if let text = json["transcript"]?.stringValue, !text.isEmpty { return [.userTranscript(text)] }
        case "input_audio_buffer.speech_started":
            return [.userStartedSpeaking, .interrupted]
        case "response.done":
            let calls = (json["response"]?["output"]?.arrayValue ?? [])
                .filter { $0["type"]?.stringValue == "function_call" }
                .map { item -> LiveToolCall in
                    let raw = item["arguments"]?.stringValue ?? "{}"
                    return LiveToolCall(id: item["call_id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "",
                                        arguments: (try? JSONValue.parse(raw)) ?? [:])
                }
            var events: [LiveEvent] = [.turnComplete]
            if !calls.isEmpty { events.append(.toolCalls(calls)) }
            if json["response"]?["status"]?.stringValue == "failed",
               let message = json["response"]?["status_details"]?["error"]?["message"]?.stringValue {
                events.append(.error(message))
            }
            return events
        case "error":
            let message = json["error"]?["message"]?.stringValue ?? "Realtime error"
            // Harmless race: cancelling a response that already finished.
            if message.lowercased().contains("no active response") { return [] }
            return [.error(message)]
        default:
            break
        }
        return []
    }
}
