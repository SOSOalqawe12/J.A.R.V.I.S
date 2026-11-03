import XCTest
import PDFKit
@testable import JARVIS

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", 2.5], "c": ["d": "e"]]
        let parsed = try JSONValue.parse(value.encodedData())
        XCTAssertEqual(parsed, value)
        XCTAssertEqual(parsed["b"]?[1]?.stringValue, "x")
        XCTAssertEqual(parsed["a"]?.intValue, 1)
        XCTAssertEqual(parsed["b"]?[0]?.boolValue, true)
    }

    func testIntegersEncodeWithoutDecimals() {
        XCTAssertEqual(JSONValue.object(["n": 16000]).jsonString(), "{\"n\":16000}")
    }

    func testExtractObjectFromFencedModelText() {
        let text = "Sure!\n```json\n{\"summary\": \"coding\", \"suggestions\": []}\n```\nDone"
        XCTAssertEqual(JSONValue.extractObject(from: text)?["summary"]?.stringValue, "coding")
        XCTAssertEqual(JSONValue.extractObject(from: "noise {\"a\": 2} noise")?["a"]?.intValue, 2)
    }
}

final class MathParserTests: XCTestCase {
    private func eval(_ text: String) throws -> Double {
        var parser = MathParser(text)
        return try parser.parse()
    }

    func testArithmetic() throws {
        XCTAssertEqual(try eval("(12.5*4)^2 / sqrt(16)"), 625)
        XCTAssertEqual(try eval("2^3^2"), 512)
        XCTAssertEqual(try eval("-3 + 5"), 2)
        XCTAssertEqual(try eval("1e3 + 1"), 1001)
        XCTAssertEqual(try eval("10 % 4"), 2)
        XCTAssertEqual(try eval("2 * pi"), 2 * Double.pi, accuracy: 1e-9)
        XCTAssertEqual(try eval("round(2.6) + abs(-1)"), 4)
    }

    func testErrors() {
        XCTAssertThrowsError(try eval("1/0"))
        XCTAssertThrowsError(try eval("(1+2"))
        XCTAssertThrowsError(try eval("foo(2)"))
    }
}

final class WorkspaceTests: XCTestCase {
    func testResolveStaysInsideWorkspace() throws {
        let workspace = Workspace.shared
        XCTAssertThrowsError(try workspace.resolve("../../etc/passwd"))
        XCTAssertThrowsError(try workspace.resolve("Notes/../../outside.txt"))
        let url = try workspace.resolve("Notes/a.txt")
        XCTAssertTrue(url.path.hasPrefix(workspace.root.standardizedFileURL.path))
        XCTAssertEqual(workspace.relativePath(of: url), "Notes/a.txt")
        XCTAssertEqual(try workspace.resolve("/Notes/a.txt"), url)
        XCTAssertEqual(try workspace.resolve(workspace.root.path + "/Notes/a.txt"), url)
    }
}

final class GeminiFormatTests: XCTestCase {
    func testContentsConvertsForeignToolCallsAndMergesTurns() {
        let call = ToolCall(id: "toolu_1", name: "create_file", arguments: ["path": "a.txt", "content": "hi"])
        let messages = [
            ChatMessage(role: .user, parts: [.text("ctx", hidden: true), .text("make a file")]),
            ChatMessage(role: .assistant, parts: [.text("On it"), .call(call)], provider: .claude),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: "toolu_1", name: "create_file", output: "Created a.txt"))]),
            ChatMessage.notice("not sent"),
            ChatMessage(role: .user, parts: [.text("thanks")])
        ]
        let contents = GeminiProvider.contents(from: messages, model: "gemini-3-flash-preview")
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[0]["role"]?.stringValue, "user")
        XCTAssertEqual(contents[1]["role"]?.stringValue, "model")
        let modelParts = contents[1]["parts"]?.arrayValue ?? []
        XCTAssertEqual(modelParts.count, 2)
        XCTAssertEqual(modelParts[1]["functionCall"]?["name"]?.stringValue, "create_file")
        XCTAssertNil(modelParts[1]["functionCall"]?["id"], "IDs Gemini didn't issue must not be sent")
        XCTAssertEqual(modelParts[1]["thoughtSignature"]?.stringValue, "skip_thought_signature_validator")
        let last = contents[2]["parts"]?.arrayValue ?? []
        XCTAssertEqual(last.first?["functionResponse"]?["response"]?["result"]?.stringValue, "Created a.txt")
        XCTAssertEqual(last.last?["text"]?.stringValue, "thanks")

        let older = GeminiProvider.contents(from: messages, model: "gemini-2.5-flash")
        XCTAssertNil(older[1]["parts"]?[1]?["thoughtSignature"], "2.x models don't need a signature")
    }

    func testParseReplyAndReplayRaw() throws {
        let json = try JSONValue.parse("""
        {"candidates":[{"content":{"role":"model","parts":[
          {"text":"Making it"},
          {"functionCall":{"name":"create_file","args":{"path":"x.txt","content":"y"}},"thoughtSignature":"abc"}
        ]},"finishReason":"STOP"}],"modelVersion":"gemini-test"}
        """)
        let reply = try GeminiProvider.parseReply(json, model: "m")
        XCTAssertEqual(reply.parts.count, 2)
        let call = try XCTUnwrap(reply.parts[1].toolCall)
        XCTAssertEqual(call.thoughtSignature, "abc")
        XCTAssertFalse(call.hasProviderID)
        XCTAssertEqual(call.arguments["path"]?.stringValue, "x.txt")

        let history = [
            ChatMessage(role: .user, parts: [.text("go")]),
            ChatMessage(role: .assistant, parts: reply.parts, provider: .gemini, providerRaw: reply.raw),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: call.id, name: call.name, output: "ok"))])
        ]
        let contents = GeminiProvider.contents(from: history, model: "gemini-3-flash-preview")
        XCTAssertEqual(contents[1]["parts"], reply.raw, "Gemini's own turns are replayed verbatim")
        XCTAssertNil(contents[2]["parts"]?[0]?["functionResponse"]?["id"])
    }

    func testBlockedPromptThrows() {
        let json: JSONValue = ["promptFeedback": ["blockReason": "SAFETY"]]
        XCTAssertThrowsError(try GeminiProvider.parseReply(json, model: "m"))
    }

    func testDeclarationOmitsEmptyParameters() {
        let empty = GeminiProvider.declaration(ToolSpec(name: "x", description: "d", parameters: Schema.object([:])))
        XCTAssertNil(empty["parameters"])
        let full = GeminiProvider.declaration(CreateFileTool().spec)
        XCTAssertNotNil(full["parameters"]?["properties"]?["path"])
    }

    func testModelPicker() {
        let ids = ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3-flash-preview", "gemini-3.1-flash-lite",
                   "gemini-2.5-flash-image", "gemini-3.1-flash-image", "gemini-3.1-flash-image-preview",
                   "gemini-2.5-flash-preview-tts", "gemini-3.1-flash-tts-preview", "gemini-embedding-001", "gemini-flash-latest"]
        let models = ids.map { GeminiModelInfo(id: $0, displayName: $0, methods: ["generateContent"]) }
        XCTAssertEqual(GeminiModelPicker.best(models, for: .chat), "gemini-3-flash-preview")
        XCTAssertEqual(GeminiModelPicker.best(models, for: .image), "gemini-3.1-flash-image")
        XCTAssertEqual(GeminiModelPicker.best(models, for: .tts), "gemini-3.1-flash-tts-preview")
        XCTAssertNil(GeminiModelPicker.best([], for: .chat))
    }

    func testWAVHeader() {
        let wav = WAVEncoder.wav(fromPCM16: Data(repeating: 0, count: 480), sampleRate: 24_000, channels: 1)
        XCTAssertEqual(wav.count, 44 + 480)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
    }
}

final class ClaudeFormatTests: XCTestCase {
    func testMessagesReplayRawAndBuildToolResults() throws {
        let raw: JSONValue = [
            ["type": "thinking", "thinking": "", "signature": "sig"],
            ["type": "tool_use", "id": "toolu_9", "name": "web_search", "input": ["query": "x"]]
        ]
        let call = ToolCall(id: "toolu_9", name: "web_search", arguments: ["query": "x"])
        let image = Attachment(name: "s.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        let history = [
            ChatMessage(role: .user, parts: [.text("search")]),
            ChatMessage(role: .assistant, parts: [.call(call)], provider: .claude, providerRaw: raw),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: "toolu_9", name: "web_search", output: "found", images: [image]))]),
            ChatMessage(role: .user, parts: [.text("ok"), .text("   ")])
        ]
        let out = ClaudeProvider.messages(from: history)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1]["content"], raw, "thinking blocks are replayed unchanged")
        let toolTurn = try XCTUnwrap(out[2]["content"]?.arrayValue)
        XCTAssertEqual(toolTurn.count, 2, "tool_result + text; whitespace-only text dropped")
        XCTAssertEqual(toolTurn[0]["type"]?.stringValue, "tool_result")
        XCTAssertEqual(toolTurn[0]["tool_use_id"]?.stringValue, "toolu_9")
        XCTAssertEqual(toolTurn[0]["content"]?[1]?["type"]?.stringValue, "image")
        XCTAssertEqual(toolTurn[1]["text"]?.stringValue, "ok")
    }

    func testForeignToolCallsBecomeToolUse() {
        let call = ToolCall(id: ToolCall.makeLocalID(), name: "create_file", arguments: ["path": "a"])
        let history = [
            ChatMessage(role: .user, parts: [.text("hi")]),
            ChatMessage(role: .assistant, parts: [.call(call)], provider: .gemini, providerRaw: ["ignored"]),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: call.id, name: call.name, output: "x", isError: true))])
        ]
        let out = ClaudeProvider.messages(from: history)
        XCTAssertEqual(out[1]["content"]?[0]?["type"]?.stringValue, "tool_use")
        XCTAssertEqual(out[1]["content"]?[0]?["id"]?.stringValue, call.id)
        XCTAssertEqual(out[2]["content"]?[0]?["is_error"]?.boolValue, true)
    }

    func testParseReply() throws {
        let json: JSONValue = [
            "model": "claude-opus-5-5",
            "stop_reason": "tool_use",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "s"],
                ["type": "text", "text": "Let me check."],
                ["type": "tool_use", "id": "toolu_1", "name": "calculate", "input": ["expression": "1+1"]]
            ]
        ]
        let reply = try ClaudeProvider.parseReply(json, requestedModel: "x")
        XCTAssertEqual(reply.parts.count, 2)
        XCTAssertEqual(reply.parts[1].toolCall?.id, "toolu_1")
        XCTAssertEqual(reply.raw?.arrayValue?.count, 3)
        XCTAssertEqual(reply.model, "claude-opus-5-5")
    }

    func testRefusalThrows() {
        let json: JSONValue = ["stop_reason": "refusal", "content": [], "stop_details": ["type": "refusal", "category": "cyber"]]
        XCTAssertThrowsError(try ClaudeProvider.parseReply(json, requestedModel: "m"))
    }

    func testSanitizeDropsDeclinedAttemptBeforeFallback() {
        let blocks: [JSONValue] = [
            ["type": "thinking", "thinking": "", "signature": "a"],
            ["type": "text", "text": "partial"],
            ["type": "tool_use", "id": "t", "name": "x", "input": [:]],
            ["type": "fallback", "from": ["model": "a"], "to": ["model": "b"]],
            ["type": "text", "text": "final"]
        ]
        let cleaned = ClaudeProvider.sanitize(blocks)
        XCTAssertEqual(cleaned.compactMap { $0["type"]?.stringValue }, ["text", "text"])
    }
}

final class PDFTests: XCTestCase {
    func testMarkdownToHTML() {
        let html = PDFMaker.markdownToHTML("# Title\n- a\n- **b**\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n1. one")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<li><b>b</b></li>"))
        XCTAssertTrue(html.contains("<th>x</th>"))
        XCTAssertTrue(html.contains("<td>2</td>"))
        XCTAssertTrue(html.contains("<ol>"))
    }

    @MainActor
    func testRenderProducesMultiPagePDF() async throws {
        let long = (1...200).map { "Paragraph \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n\n")
        let data = try await PDFMaker.render(html: PDFMaker.html(from: "# Hello\n\n" + long, title: "Test"), title: "Test")
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Hello") == true)
    }
}

@MainActor
final class ToolTests: XCTestCase {
    private let folder = ".jarvis-tests-\(UUID().uuidString.prefix(8))"

    private var context: ToolContext {
        ToolContext(workspace: .shared, settings: .shared, approvals: .shared)
    }

    override func tearDown() async throws {
        let root = Workspace.shared.root
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder + ".zip"))
    }

    func testFileLifecycle() async throws {
        let path = "\(folder)/notes.txt"
        let created = try await CreateFileTool().run(["path": .string(path), "content": "hello"], context: context)
        XCTAssertEqual(created.files, [path])
        let duplicate = try await CreateFileTool().run(["path": .string(path), "content": "copy"], context: context)
        XCTAssertEqual(duplicate.files, ["\(folder)/notes (2).txt"])

        _ = try await AppendFileTool().run(["path": .string(path), "content": " world"], context: context)
        _ = try await EditFileTool().run(["path": .string(path), "find": "world", "replace": "JARVIS"], context: context)
        let read = try await ReadFileTool().run(["path": .string(path)], context: context)
        XCTAssertEqual(read.text, "hello JARVIS")

        let listing = try await ListFilesTool().run(["path": .string(folder)], context: context)
        XCTAssertTrue(listing.text.contains("notes.txt"))

        let moved = try await MoveFileTool().run(["from": .string("\(folder)/notes (2).txt"), "to": .string("\(folder)/Sub/renamed.md")], context: context)
        XCTAssertEqual(moved.files, ["\(folder)/Sub/renamed.md"])

        let zipped = try await ZipFolderTool().run(["path": .string(folder)], context: context)
        let zipURL = try Workspace.shared.resolve(try XCTUnwrap(zipped.files.first))
        let zipData = try Data(contentsOf: zipURL)
        XCTAssertEqual(Array(zipData.prefix(2)), [0x50, 0x4B], "zip magic number")

        do {
            _ = try await CreateFileTool().run(["path": "../escape.txt", "content": "x"], context: context)
            XCTFail("Writing outside the workspace must fail")
        } catch {}
    }

    func testMediaTools() async throws {
        let qr = try await CreateQRCodeTool().run(["text": "https://apple.com", "path": .string("\(folder)/qr")], context: context)
        let qrURL = try Workspace.shared.resolve(try XCTUnwrap(qr.files.first))
        XCTAssertEqual(qrURL.pathExtension, "png")
        XCTAssertNotNil(ImageCoder.cgImage(from: try Data(contentsOf: qrURL)))

        let chart = try await CreateChartTool().run([
            "path": .string("\(folder)/chart.png"), "title": "Week", "chart_type": "bar",
            "labels": ["Mon", "Tue", "Wed"], "values": [3, 5, 2]
        ], context: context)
        let chartURL = try Workspace.shared.resolve(try XCTUnwrap(chart.files.first))
        let chartImage = try XCTUnwrap(ImageCoder.cgImage(from: try Data(contentsOf: chartURL)))
        XCTAssertGreaterThan(chartImage.width, 1000)

        let pdf = try await CreatePDFTool().run([
            "path": .string("\(folder)/report"), "content": "# Report\n\n- one\n- two", "title": "Report"
        ], context: context)
        let pdfURL = try Workspace.shared.resolve(try XCTUnwrap(pdf.files.first))
        XCTAssertEqual(pdfURL.pathExtension, "pdf")
        XCTAssertNotNil(PDFDocument(url: pdfURL))

        let math = try await CalculatorTool().run(["expression": "2+2*3"], context: context)
        XCTAssertTrue(math.text.hasSuffix("= 8"))
    }

    func testToolNamesAreUniqueAndValid() {
        let names = (Toolbox.sharedTools() + MacTools.all).map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        for name in names {
            XCTAssertNotNil(name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression), name)
        }
    }
}
