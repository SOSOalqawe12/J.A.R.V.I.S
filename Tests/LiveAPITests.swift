import XCTest
@testable import JARVIS

/// Real API round trips. Skipped unless keys are provided, e.g. in CI via the
/// GEMINI_API_KEY / ANTHROPIC_API_KEY repository secrets.
final class LiveAPITests: XCTestCase {
    private func key(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) not set – live test skipped")
        }
        return value
    }

    private let instructions = "You are an automated test. Follow instructions exactly and briefly."
    private let prompt = "Create a file named hello.txt containing exactly the word hi. Use the create_file tool."

    private func roundTrip(provider: LLMProvider) async throws {
        let tool = CreateFileTool().spec
        var history = [ChatMessage(role: .user, parts: [.text(prompt)])]
        let first = try await provider.complete(LLMRequest(system: instructions, messages: history, tools: [tool]))
        let call = try XCTUnwrap(first.parts.compactMap(\.toolCall).first, "model should call the tool")
        XCTAssertEqual(call.name, "create_file")
        XCTAssertEqual(call.arguments["path"]?.stringValue?.hasSuffix("hello.txt"), true)

        history.append(ChatMessage(role: .assistant, parts: first.parts, provider: provider.kind, model: first.model, providerRaw: first.raw))
        history.append(ChatMessage(role: .tool, parts: [.result(ToolResult(callID: call.id, name: call.name, output: "Created hello.txt", files: ["hello.txt"]))]))
        let second = try await provider.complete(LLMRequest(system: instructions, messages: history, tools: [tool]))
        XCTAssertFalse(second.parts.isEmpty)
    }

    func testGeminiToolRoundTrip() async throws {
        let apiKey = try key("JARVIS_TEST_GEMINI_KEY")
        let client = GeminiClient(apiKey: apiKey)
        let models = try await client.listModels()
        XCTAssertFalse(models.isEmpty)
        let model = GeminiModelPicker.best(models, for: .chat) ?? GeminiModelPicker.fallbackChat
        try await roundTrip(provider: GeminiProvider(client: client, model: model))
    }

    func testGeminiImageGeneration() async throws {
        let apiKey = try key("JARVIS_TEST_GEMINI_KEY")
        let client = GeminiClient(apiKey: apiKey)
        let models = try await client.listModels()
        let model = GeminiModelPicker.best(models, for: .image) ?? GeminiModelPicker.fallbackImage
        let image = try await client.generateImage(prompt: "A small flat blue circle icon on white", inputs: [], aspectRatio: "1:1", model: model)
        XCTAssertNotNil(ImageCoder.cgImage(from: image.data))
    }

    func testClaudeToolRoundTrip() async throws {
        let apiKey = try key("JARVIS_TEST_ANTHROPIC_KEY")
        let provider = ClaudeProvider(client: ClaudeClient(apiKey: apiKey), model: ClaudeClient.defaultModel,
                                      effort: "low", useRefusalFallback: true)
        try await roundTrip(provider: provider)
    }
}
