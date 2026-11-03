import XCTest
@testable import JARVIS

final class LiveTransportTests: XCTestCase {
    func testGeminiSetupIncludesLimitsFixesUnlessMinimal() {
        let transport = GeminiLiveTransport(apiKey: "k", model: "gemini-live-x", voice: "Charon")
        let full = transport.setupMessages(system: "SYS", tools: [CalculatorTool().spec], resumeHandle: "h1", minimal: false)[0]["setup"]
        XCTAssertEqual(full?["model"]?.stringValue, "models/gemini-live-x")
        XCTAssertEqual(full?["generationConfig"]?["mediaResolution"]?.stringValue, "MEDIA_RESOLUTION_LOW")
        XCTAssertEqual(full?["sessionResumption"]?["handle"]?.stringValue, "h1")
        XCTAssertNotNil(full?["contextWindowCompression"])
        XCTAssertEqual(full?["tools"]?[0]?["functionDeclarations"]?[0]?["name"]?.stringValue, "calculate")

        let minimal = transport.setupMessages(system: "SYS", tools: [], resumeHandle: nil, minimal: true)[0]["setup"]
        XCTAssertNil(minimal?["sessionResumption"])
        XCTAssertNil(minimal?["generationConfig"]?["mediaResolution"])
        XCTAssertEqual(minimal?["generationConfig"]?["responseModalities"]?[0]?.stringValue, "AUDIO")
    }

    func testGeminiParse() throws {
        let transport = GeminiLiveTransport(apiKey: "k", model: "m", voice: "v")
        let audio = Data([1, 0, 2, 0]).base64EncodedString()
        let message = try JSONValue.parse("""
        {"serverContent": {"interrupted": true, "inputTranscription": {"text": "hi"}, "outputTranscription": {"text": "hello"},
          "modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\(audio)"}}]}, "turnComplete": true}}
        """)
        let events = transport.parse(message)
        XCTAssertEqual(events.count, 5)
        if case .interrupted = events[0] {} else { XCTFail("expected interrupted") }
        if case .userTranscript(let text) = events[1] { XCTAssertEqual(text, "hi") } else { XCTFail() }
        if case .modelTranscript(let text) = events[2] { XCTAssertEqual(text, "hello") } else { XCTFail() }
        if case .audio(let data) = events[3] { XCTAssertEqual(data.count, 4) } else { XCTFail() }
        if case .turnComplete = events[4] {} else { XCTFail() }

        let tool = transport.parse(try JSONValue.parse(#"{"toolCall": {"functionCalls": [{"id": "c1", "name": "set_timer", "args": {"minutes": 5}}]}}"#))
        if case .toolCalls(let calls) = tool.first {
            XCTAssertEqual(calls.first?.id, "c1")
            XCTAssertEqual(calls.first?.arguments["minutes"]?.intValue, 5)
        } else { XCTFail("expected tool calls") }

        let resume = transport.parse(try JSONValue.parse(#"{"sessionResumptionUpdate": {"newHandle": "abc", "resumable": true}, "goAway": {"timeLeft": "10s"}}"#))
        if case .resumptionHandle(let handle) = resume.first { XCTAssertEqual(handle, "abc") } else { XCTFail() }
        if case .goAway = resume.last {} else { XCTFail() }
        if case .ready = transport.parse(["setupComplete": [:]]).first {} else { XCTFail() }

        let results = transport.toolResultMessages([LiveToolResult(call: LiveToolCall(id: "c1", name: "set_timer", arguments: [:]), output: "ok", isError: false)])
        XCTAssertEqual(results[0]["toolResponse"]?["functionResponses"]?[0]?["id"]?.stringValue, "c1")
        XCTAssertEqual(results[0]["toolResponse"]?["functionResponses"]?[0]?["response"]?["result"]?.stringValue, "ok")
    }

    func testOpenAIRealtimeParse() throws {
        let transport = OpenAIRealtimeTransport(apiKey: "k", model: "gpt-realtime", voice: "cedar")
        XCTAssertEqual(transport.micSampleRate, 24_000)
        let session = transport.setupMessages(system: "SYS", tools: [CalculatorTool().spec], resumeHandle: nil, minimal: false)[0]
        XCTAssertEqual(session["type"]?.stringValue, "session.update")
        XCTAssertEqual(session["session"]?["audio"]?["output"]?["voice"]?.stringValue, "cedar")
        XCTAssertEqual(session["session"]?["tools"]?[0]?["name"]?.stringValue, "calculate")

        if case .ready = transport.parse(["type": "session.updated"]).first {} else { XCTFail() }
        let audio = Data([0, 1]).base64EncodedString()
        for type in ["response.output_audio.delta", "response.audio.delta"] {
            if case .audio(let data) = transport.parse(["type": .string(type), "delta": .string(audio)]).first {
                XCTAssertEqual(data.count, 2)
            } else { XCTFail(type) }
        }
        let done = transport.parse(try JSONValue.parse(#"{"type": "response.done", "response": {"output": [{"type": "function_call", "call_id": "x1", "name": "get_weather", "arguments": "{\"location\":\"Paris\"}"}]}}"#))
        XCTAssertEqual(done.count, 2)
        if case .toolCalls(let calls) = done.last {
            XCTAssertEqual(calls.first?.id, "x1")
            XCTAssertEqual(calls.first?.arguments["location"]?.stringValue, "Paris")
        } else { XCTFail() }
        XCTAssertTrue(transport.parse(["type": "error", "error": ["message": "Cancellation failed: no active response found"]]).isEmpty)
        let speech = transport.parse(["type": "input_audio_buffer.speech_started"])
        XCTAssertEqual(speech.count, 2)

        let outputs = transport.toolResultMessages([LiveToolResult(call: LiveToolCall(id: "x1", name: "get_weather", arguments: [:]), output: "Sunny", isError: false)])
        XCTAssertEqual(outputs.first?["item"]?["call_id"]?.stringValue, "x1")
        XCTAssertEqual(outputs.last?["type"]?.stringValue, "response.create")
    }
}

final class LimitTests: XCTestCase {
    func testRateLimitDetection() {
        XCTAssertTrue(LLMError.http(status: 429, message: "Too many requests").isRateLimit)
        XCTAssertTrue(LLMError.http(status: 400, message: "You exceeded your current quota").isRateLimit)
        XCTAssertTrue(LLMError.http(status: 529, message: "Overloaded").isRateLimit)
        XCTAssertFalse(LLMError.http(status: 401, message: "Invalid API key").isRateLimit)
        XCTAssertFalse(LLMError.emptyResponse("x").isRateLimit)
    }

    func testRetryDelayParsing() throws {
        let json = try JSONValue.parse(#"{"error": {"code": 429, "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "17s"}]}}"#)
        XCTAssertEqual(HTTP.retryDelay(nil, json: json), 17)
        XCTAssertNil(HTTP.retryDelay(nil, json: ["error": ["message": "x"]]))
    }

    @MainActor
    func testUsageTracker() {
        let tracker = UsageTracker.shared
        tracker.reset()
        tracker.record(.gemini, tokens: 1200)
        tracker.record(.gemini, tokens: 300)
        tracker.record(.local, tokens: nil)
        XCTAssertEqual(tracker.today.first?.provider, .gemini)
        XCTAssertEqual(tracker.today.first?.entry.requests, 2)
        XCTAssertEqual(tracker.today.first?.entry.tokens, 1500)
        XCTAssertEqual(tracker.total(lastDays: 7).requests, 3)
        tracker.reset()
        XCTAssertTrue(tracker.today.isEmpty)
    }

    @MainActor
    func testEngineResolution() {
        let settings = AppSettings.shared
        let saved = (settings.liveEngine, settings.geminiAPIKey, settings.openAIAPIKey)
        defer {
            settings.liveEngine = saved.0
            settings.geminiAPIKey = saved.1
            settings.openAIAPIKey = saved.2
        }
        settings.geminiAPIKey = ""
        settings.openAIAPIKey = ""
        settings.liveEngine = "auto"
        XCTAssertEqual(LiveEngineKind.resolve(settings), .classic)
        settings.openAIAPIKey = "sk-test"
        XCTAssertEqual(LiveEngineKind.resolve(settings), .openai)
        settings.liveEngine = "gemini"
        XCTAssertEqual(LiveEngineKind.resolve(settings), .classic, "falls back when the chosen engine has no key")
    }
}
