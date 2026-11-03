import XCTest
@testable import JARVIS

final class OpenAICompatibleTests: XCTestCase {
    private var history: [ChatMessage] {
        let call = ToolCall(id: "call_1", name: "create_file", arguments: ["path": "a.txt", "content": "hi"])
        let image = Attachment(name: "p.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        return [
            ChatMessage(role: .user, parts: [.text("ctx", hidden: true), .text("make a file"), .attachment(image)]),
            ChatMessage(role: .assistant, parts: [.text("On it"), .call(call)], provider: .gemini),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: "call_1", name: "create_file", output: "Created a.txt", images: [image]))]),
            ChatMessage.notice("not sent"),
            ChatMessage(role: .user, parts: [.text("thanks")])
        ]
    }

    func testNativeMessages() throws {
        let out = OpenAICompatibleProvider.messages(from: history, system: "SYS", mode: .native)
        XCTAssertEqual(out.map { $0["role"]?.stringValue ?? "" }, ["system", "user", "assistant", "tool", "user", "user"])
        let userContent = try XCTUnwrap(out[1]["content"]?.arrayValue)
        XCTAssertEqual(userContent.last?["type"]?.stringValue, "image_url")
        XCTAssertTrue(userContent.last?["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/jpeg;base64,") == true)
        let toolCall = try XCTUnwrap(out[2]["tool_calls"]?[0])
        XCTAssertEqual(toolCall["function"]?["name"]?.stringValue, "create_file")
        let arguments = try JSONValue.parse(try XCTUnwrap(toolCall["function"]?["arguments"]?.stringValue))
        XCTAssertEqual(arguments["path"]?.stringValue, "a.txt")
        XCTAssertEqual(out[3]["tool_call_id"]?.stringValue, "call_1")
        XCTAssertEqual(out[4]["content"]?[1]?["type"]?.stringValue, "image_url", "tool images follow as a user message")
        XCTAssertEqual(out[5]["content"]?.stringValue, "thanks", "plain text stays a string for local-server compatibility")
    }

    func testPromptedMessages() {
        let out = OpenAICompatibleProvider.messages(from: history, system: "SYS", mode: .prompted)
        XCTAssertFalse(out.contains { $0["role"]?.stringValue == "tool" })
        XCTAssertTrue(out[2]["content"]?.stringValue?.contains("<tool_call>") == true)
        let toolTurn = out[3]["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(toolTurn.contains("<tool_response name=\"create_file\">"))
    }

    func testParseNativeToolCallsAndStripThinking() throws {
        let message: JSONValue = [
            "role": "assistant",
            "content": "<think>planning…</think>Sure!",
            "tool_calls": [["id": "call_9", "type": "function", "function": ["name": "calculate", "arguments": "{\"expression\":\"2+2\"}"]]]
        ]
        let reply = try OpenAICompatibleProvider.parse(message: message, finishReason: "tool_calls", model: "m", prompted: false)
        XCTAssertEqual(reply.parts.count, 2)
        XCTAssertEqual(reply.parts[0].text, "Sure!")
        XCTAssertEqual(reply.parts[1].toolCall?.id, "call_9")
        XCTAssertEqual(reply.parts[1].toolCall?.arguments["expression"]?.stringValue, "2+2")
    }

    func testParsePromptedToolCall() throws {
        let message: JSONValue = ["role": "assistant", "content": "Saving it.\n<tool_call>{\"name\": \"create_file\", \"arguments\": {\"path\": \"n.txt\", \"content\": \"x\"}}</tool_call>"]
        let reply = try OpenAICompatibleProvider.parse(message: message, finishReason: "stop", model: "m", prompted: true)
        XCTAssertEqual(reply.parts.first?.text, "Saving it.")
        XCTAssertEqual(reply.parts.last?.toolCall?.name, "create_file")
        XCTAssertEqual(reply.parts.last?.toolCall?.arguments["path"]?.stringValue, "n.txt")
    }

    func testEmptyReplyThrows() {
        XCTAssertThrowsError(try OpenAICompatibleProvider.parse(message: ["content": ""], finishReason: "stop", model: "m", prompted: false))
    }

    func testStreamAccumulator() throws {
        var accumulator = OpenAIStreamAccumulator()
        XCTAssertTrue(accumulator.add(["choices": [["delta": ["content": "Hel"]]]]))
        XCTAssertTrue(accumulator.add(["choices": [["delta": ["content": "lo"]]]]))
        accumulator.add(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_a", "function": ["name": "remember", "arguments": "{\"fa"]]]]]]])
        accumulator.add(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "ct\":\"likes tea\"}"]]]], "finish_reason": "tool_calls"]]])
        XCTAssertEqual(accumulator.content, "Hello")
        XCTAssertEqual(accumulator.finishReason, "tool_calls")
        let reply = try OpenAICompatibleProvider.parse(message: accumulator.message, finishReason: accumulator.finishReason, model: "m", prompted: false)
        XCTAssertEqual(reply.parts.last?.toolCall?.arguments["fact"]?.stringValue, "likes tea")
        XCTAssertEqual(reply.parts.last?.toolCall?.id, "call_a")
    }

    func testToolSupportErrorDetection() {
        XCTAssertTrue(OpenAICompatibleProvider.isToolSupportError(400, "registry.ollama.ai/library/gemma:2b does not support tools"))
        XCTAssertFalse(OpenAICompatibleProvider.isToolSupportError(401, "invalid api key"))
        XCTAssertFalse(OpenAICompatibleProvider.isToolSupportError(500, "tools not supported"))
    }

    func testBestOpenAIModel() {
        let ids = ["gpt-4o", "gpt-4o-mini", "gpt-5", "gpt-5-mini", "gpt-4o-audio-preview", "dall-e-3", "gpt-5.1", "gpt-5.1-2025-11-13", "text-embedding-3-large"]
        XCTAssertEqual(OpenAICompatibleClient.bestOpenAIModel(ids), "gpt-5.1")
        XCTAssertNil(OpenAICompatibleClient.bestOpenAIModel(["whisper-1"]))
    }

    func testImageSizes() {
        XCTAssertEqual(OpenAICompatibleClient.imageSize(for: "9:16"), "1024x1536")
        XCTAssertEqual(OpenAICompatibleClient.imageSize(for: "16:9"), "1536x1024")
        XCTAssertEqual(OpenAICompatibleClient.imageSize(for: nil), "1024x1024")
    }
}

final class PromptedToolsTests: XCTestCase {
    func testInstructionsDescribeTools() {
        let text = PromptedTools.instructions(for: [CreateFileTool().spec, CalculatorTool().spec])
        XCTAssertTrue(text.contains("<tool_call>"))
        XCTAssertTrue(text.contains("create_file(content: string, overwrite?: boolean, path: string)"))
        XCTAssertTrue(text.contains("calculate(expression: string)"))
        XCTAssertEqual(PromptedTools.instructions(for: []), "")
    }

    func testExtractMultipleCallsAndStringArguments() {
        let text = """
        Doing both.
        <tool_call>{"name": "set_timer", "arguments": "{\\"minutes\\": 5, \\"title\\": \\"Tea\\"}"}</tool_call>
        <tool_call>{"name": "remember", "parameters": {"fact": "Likes tea"}}</tool_call>
        """
        let result = PromptedTools.extract(text)
        XCTAssertEqual(result.text, "Doing both.")
        XCTAssertEqual(result.calls.map(\.name), ["set_timer", "remember"])
        XCTAssertEqual(result.calls[0].arguments["minutes"]?.intValue, 5)
        XCTAssertEqual(result.calls[1].arguments["fact"]?.stringValue, "Likes tea")
    }

    func testStripReasoning() {
        XCTAssertEqual(PromptedTools.stripReasoning("<think>hmm</think>\nAnswer"), "Answer")
        XCTAssertEqual(PromptedTools.stripReasoning("Partial <think>still thinking"), "Partial")
    }

    func testTranscriptRespectsBudget() {
        let messages = (1...50).map { ChatMessage(role: .user, parts: [.text("Message number \($0) with some padding text")]) }
        let transcript = PromptedTools.transcript(messages, characterBudget: 500)
        XCTAssertLessThanOrEqual(transcript.count, 600)
        XCTAssertTrue(transcript.contains("Message number 50"))
        XCTAssertFalse(transcript.contains("Message number 1 "))
    }
}

final class MiscFeatureTests: XCTestCase {
    func testDuckDuckGoParsing() {
        let html = """
        <div class="result"><h2><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=abc">Example <b>Page</b></a></h2>
        <a class="result__snippet" href="x">This is the <b>snippet</b>.</a></div>
        <div class="result"><a rel="nofollow" class="result__a" href="https://direct.example.org/">Direct</a><a class="result__snippet">Second snippet</a></div>
        """
        let results = DuckDuckGo.parse(html)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Example Page")
        XCTAssertEqual(results[0].url, "https://example.com/page")
        XCTAssertTrue(results[0].snippet.contains("snippet"))
        XCTAssertEqual(results[1].url, "https://direct.example.org/")
    }

    func testConversationMarkdownExport() {
        var conversation = Conversation(systemPrompt: "")
        conversation.title = "Trip"
        conversation.messages = [
            ChatMessage(role: .user, parts: [.text("ctx", hidden: true), .text("Plan Paris")]),
            ChatMessage(role: .assistant, parts: [.text("Here's the plan")]),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: "1", name: "create_file", output: "ok", files: ["Notes/Paris.md"]))])
        ]
        let markdown = ConversationExporter.markdown(conversation)
        XCTAssertTrue(markdown.hasPrefix("# Trip"))
        XCTAssertTrue(markdown.contains("**You:** Plan Paris"))
        XCTAssertFalse(markdown.contains("ctx"), "hidden context isn't exported")
        XCTAssertTrue(markdown.contains("**JARVIS:** Here's the plan"))
        XCTAssertTrue(markdown.contains("📁 Created: Notes/Paris.md"))
    }

    func testProviderListIncludesNewBrains() {
        XCTAssertTrue(ProviderKind.available.contains(.openai))
        XCTAssertTrue(ProviderKind.available.contains(.local))
        XCTAssertTrue(ProviderKind.available.contains(.apple))
        XCTAssertFalse(AppleIntelligence.status.isEmpty)
    }
}
