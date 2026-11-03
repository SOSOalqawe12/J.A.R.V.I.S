import XCTest
@testable import JARVIS

final class StreamingTests: XCTestCase {
    private func chunk(_ parts: [JSONValue], finish: String? = nil) -> JSONValue {
        var candidate: [String: JSONValue] = ["content": ["role": "model", "parts": .array(parts)]]
        if let finish { candidate["finishReason"] = .string(finish) }
        return ["candidates": [.object(candidate)], "modelVersion": "gemini-test"]
    }

    func testAccumulatorMergesTextAndKeepsCallsAndSignatures() throws {
        var accumulator = GeminiStreamAccumulator()
        XCTAssertTrue(accumulator.add(chunk([["text": "Hel"]])))
        XCTAssertTrue(accumulator.add(chunk([["text": "lo"]])))
        XCTAssertEqual(accumulator.visibleText, "Hello")
        XCTAssertFalse(accumulator.add(chunk([
            ["functionCall": ["name": "create_file", "args": ["path": "a.txt", "content": "x"]], "thoughtSignature": "sig1"]
        ])))
        accumulator.add(chunk([["text": "", "thoughtSignature": "sig2"]], finish: "STOP"))

        XCTAssertEqual(accumulator.parts.count, 3)
        let reply = try GeminiProvider.parseReply(accumulator.response(model: "m"), model: "m")
        XCTAssertEqual(reply.parts.count, 2)
        XCTAssertEqual(reply.parts[0].text, "Hello")
        XCTAssertEqual(reply.parts[1].toolCall?.thoughtSignature, "sig1")
        XCTAssertEqual(reply.stopReason, "STOP")
        XCTAssertEqual(reply.raw?[2]?["thoughtSignature"]?.stringValue, "sig2", "signatures are kept for replay")
    }

    func testAccumulatorDoesNotMergeIntoSignedText() {
        var accumulator = GeminiStreamAccumulator()
        accumulator.add(chunk([["text": "A", "thoughtSignature": "s"]]))
        accumulator.add(chunk([["text": "B"]]))
        XCTAssertEqual(accumulator.parts.count, 2)
        XCTAssertEqual(accumulator.visibleText, "AB")
    }

    func testBlockedStreamThrows() {
        var accumulator = GeminiStreamAccumulator()
        accumulator.add(["promptFeedback": ["blockReason": "SAFETY"]])
        XCTAssertThrowsError(try GeminiProvider.parseReply(accumulator.response(model: "m"), model: "m"))
    }
}

final class ParsingTests: XCTestCase {
    func testDateParser() throws {
        let date = try XCTUnwrap(DateParser.parse("2026-11-04 13:30"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 11, 4, 13, 30])
        XCTAssertNotNil(DateParser.parse("2026-11-04T13:30:00Z"))
        XCTAssertNotNil(DateParser.parse("2026-11-04T13:30"))
        XCTAssertNotNil(DateParser.parse("2026-11-04"))
        XCTAssertTrue(DateParser.isDateOnly("2026-11-04"))
        XCTAssertFalse(DateParser.isDateOnly("2026-11-04 10:00"))
        XCTAssertNil(DateParser.parse("next tuesday-ish"))
    }

    func testWakeWordDetection() {
        XCTAssertEqual(WakeWordListener.detect(in: "Hey Jarvis, what's the weather?"), "what's the weather")
        XCTAssertEqual(WakeWordListener.detect(in: "hey JARVIS"), "")
        XCTAssertEqual(WakeWordListener.detect(in: "مرحبا جارفيس افتح الملاحظات"), "افتح الملاحظات")
        XCTAssertNil(WakeWordListener.detect(in: "what's the weather"))
    }

    func testWeatherCodes() {
        XCTAssertEqual(WeatherCodes.describe(0), "clear sky")
        XCTAssertEqual(WeatherCodes.describe(95), "thunderstorm")
        XCTAssertTrue(WeatherCodes.describe(1234).contains("1234"))
    }

    func testLiveModelPicker() {
        let models = [
            GeminiModelInfo(id: "gemini-2.5-flash", displayName: "", methods: ["generateContent"]),
            GeminiModelInfo(id: "gemini-live-2.5-flash-preview", displayName: "", methods: ["bidiGenerateContent"]),
            GeminiModelInfo(id: "gemini-2.5-flash-native-audio-preview-09-2025", displayName: "", methods: ["bidiGenerateContent"]),
            GeminiModelInfo(id: "gemini-3-flash-native-audio-preview", displayName: "", methods: ["bidiGenerateContent", "countTokens"])
        ]
        XCTAssertEqual(GeminiModelPicker.best(models, for: .live), "gemini-3-flash-native-audio-preview")
        XCTAssertEqual(GeminiModelPicker.best(models, for: .chat), "gemini-2.5-flash")
        XCTAssertNil(GeminiModelPicker.best(Array(models.prefix(1)), for: .live))
    }

    func testModesHaveDistinctPrompts() {
        let instructions = AssistantMode.allCases.compactMap(\.instructions)
        XCTAssertEqual(instructions.count, AssistantMode.allCases.count - 1)
        XCTAssertEqual(Set(instructions).count, instructions.count)
    }
}

@MainActor
final class UpgradeToolTests: XCTestCase {
    func testMemoryToolsRoundTrip() async throws {
        let context = ToolContext(workspace: .shared, settings: .shared, approvals: .shared)
        let marker = "Test fact \(UUID().uuidString)"
        _ = try await RememberTool().run(["fact": .string(marker)], context: context)
        XCTAssertTrue(MemoryStore.shared.items.contains { $0.text == marker })
        let recall = try await RecallTool().run([:], context: context)
        XCTAssertTrue(recall.text.contains(marker))
        let forget = try await ForgetTool().run(["query": .string(marker)], context: context)
        XCTAssertTrue(forget.text.contains(marker))
        XCTAssertFalse(MemoryStore.shared.items.contains { $0.text == marker })
    }

    func testSystemPromptIncludesModeAndMemory() {
        let marker = "Loves testing \(UUID().uuidString.prefix(6))"
        MemoryStore.shared.add(marker)
        defer { _ = MemoryStore.shared.remove(matching: marker) }
        let prompt = SystemPrompts.make(settings: .shared, mode: .chef)
        XCTAssertTrue(prompt.contains("Current mode: Chef"))
        XCTAssertTrue(prompt.contains(marker))
    }

    func testOCRReadsRenderedText() async throws {
        // Render "JARVIS 2026" into a PDF page and read it back.
        let html = PDFMaker.html(from: "<h1>JARVIS 2026</h1>", title: nil)
        let data = try await PDFMaker.render(html: html, title: nil)
        let folder = ".jarvis-ocr-\(UUID().uuidString.prefix(6))"
        let url = try Workspace.shared.destination(for: "\(folder)/scan.pdf", overwrite: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try data.write(to: url)
        let context = ToolContext(workspace: .shared, settings: .shared, approvals: .shared)
        let output = try await ExtractTextTool().run(["path": .string("\(folder)/scan.pdf")], context: context)
        XCTAssertTrue(output.text.contains("JARVIS"), output.text)
    }
}
