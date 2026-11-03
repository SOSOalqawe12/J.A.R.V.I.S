import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import JARVIS

final class VisionBridgeTests: XCTestCase {
    func testImageSupportHeuristics() {
        XCTAssertFalse(VisionBridge.supportsImages(model: "deepseek-chat", kind: .deepseek))
        XCTAssertFalse(VisionBridge.supportsImages(model: "deepseek-reasoner", kind: .local))
        XCTAssertTrue(VisionBridge.supportsImages(model: "deepseek-vl2", kind: .local))
        XCTAssertTrue(VisionBridge.supportsImages(model: "llava:13b", kind: .local))
        XCTAssertTrue(VisionBridge.supportsImages(model: "qwen2.5vl:7b", kind: .local))
        XCTAssertTrue(VisionBridge.supportsImages(model: "gemma3:12b", kind: .local))
        XCTAssertFalse(VisionBridge.supportsImages(model: "qwen2.5:7b", kind: .local))
        XCTAssertFalse(VisionBridge.supportsImages(model: "llama3.1:8b", kind: .local))
        XCTAssertTrue(VisionBridge.supportsImages(model: "gpt-4o-mini", kind: .openai))
        XCTAssertFalse(VisionBridge.supportsImages(model: "anything", kind: .apple))
    }

    private func qrPNG(_ text: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        return try XCTUnwrap(ImageCoder.encode(cgImage, type: .png))
    }

    func testOnDeviceDescriptionReadsCodes() throws {
        let description = VisionBridge.onDevice(try qrPNG("https://jarvis.example/hello"))
        XCTAssertTrue(description.hasPrefix("on-device analysis"))
        XCTAssertTrue(description.contains("jarvis.example/hello"), description)
    }

    @MainActor
    func testTextOnlyReplacesImagesWithDescriptions() async throws {
        let settings = AppSettings.shared
        let saved = (settings.geminiAPIKey, settings.openAIAPIKey)
        settings.geminiAPIKey = ""
        settings.openAIAPIKey = ""
        defer {
            settings.geminiAPIKey = saved.0
            settings.openAIAPIKey = saved.1
        }
        let image = Attachment(name: "Camera.jpg", mimeType: "image/png", data: try qrPNG("JARVIS-CAM"))
        let messages = [
            ChatMessage(role: .user, parts: [.text("What's this?"), .attachment(image)]),
            ChatMessage(role: .tool, parts: [.result(ToolResult(callID: "1", name: "capture_screen", output: "Screenshot", images: [image]))])
        ]
        XCTAssertTrue(VisionBridge.containsImages(messages))
        let converted = await VisionBridge.textOnly(messages, settings: settings)
        XCTAssertFalse(VisionBridge.containsImages(converted))
        let text = converted[0].parts.compactMap(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("[Image \"Camera.jpg\""))
        XCTAssertTrue(text.contains("JARVIS-CAM"), text)
        XCTAssertTrue(converted[1].toolResults[0].output.contains("JARVIS-CAM"))
    }

    func testImageErrorDetection() {
        XCTAssertTrue(OpenAICompatibleProvider.isImageSupportError(400, "Failed to deserialize the JSON body: unknown variant `image_url`, expected `text`"))
        XCTAssertTrue(OpenAICompatibleProvider.isImageSupportError(422, "This model does not support vision"))
        XCTAssertFalse(OpenAICompatibleProvider.isImageSupportError(500, "image service down"))
        XCTAssertFalse(OpenAICompatibleProvider.isImageSupportError(401, "bad key"))
    }

    @MainActor
    func testDeepSeekProvider() async throws {
        let settings = AppSettings.shared
        let saved = (settings.deepSeekAPIKey, settings.deepSeekModel)
        defer {
            settings.deepSeekAPIKey = saved.0
            settings.deepSeekModel = saved.1
        }
        settings.deepSeekAPIKey = "sk-test"
        settings.deepSeekModel = "deepseek-chat"
        XCTAssertTrue(settings.isConfigured(.deepseek))
        let provider = try await AgentEngine.makeProvider(kind: .deepseek, settings: settings)
        let openAICompatible = try XCTUnwrap(provider as? OpenAICompatibleProvider)
        XCTAssertEqual(openAICompatible.kind, .deepseek)
        XCTAssertEqual(openAICompatible.model, "deepseek-chat")
        XCTAssertTrue(openAICompatible.describeImages)
        XCTAssertTrue(ProviderKind.available.contains(.deepseek))
    }
}
