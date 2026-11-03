import Foundation
import SwiftUI
import Charts
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import UniformTypeIdentifiers

private func fileExtension(forImageMime mime: String) -> String {
    switch mime {
    case "image/jpeg": return "jpg"
    case "image/webp": return "webp"
    case "image/gif": return "gif"
    default: return "png"
    }
}

/// Writes generated image data, making sure the extension matches the real format.
private func saveImage(_ image: GeminiClient.GeneratedImage, to path: String, context: ToolContext) throws -> String {
    let ext = fileExtension(forImageMime: image.mimeType)
    var adjusted = path
    let currentExt = (path as NSString).pathExtension.lowercased()
    if currentExt.isEmpty {
        adjusted = path + "." + ext
    } else if currentExt != ext && !(currentExt == "jpeg" && ext == "jpg") {
        adjusted = (path as NSString).deletingPathExtension + "." + ext
    }
    let url = try context.workspace.destination(for: adjusted, overwrite: false)
    try image.data.write(to: url)
    return context.workspace.relativePath(of: url)
}

private func loadImageAttachment(_ path: String, context: ToolContext) throws -> Attachment {
    let url = try context.workspace.resolve(path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(path) }
    let data = try Data(contentsOf: url)
    guard let prepared = ImageCoder.preparedForModel(data, maxPixel: 2048) else {
        throw ToolError.invalid("\(path) is not a readable image.")
    }
    return Attachment(name: url.lastPathComponent, mimeType: prepared.mimeType, data: prepared.data)
}

// MARK: - Images

struct GenerateImageTool: AgentTool {
    let name = "generate_image"
    let activityLabel = "Painting image"
    let description = """
    Generate a picture (photo, illustration, wallpaper, logo, icon, poster…) with Gemini's image model and save it \
    in the JARVIS folder. Write a rich, specific prompt (subject, style, lighting, composition, colours, text to render). \
    Optionally pass existing images from the folder as references.
    """
    let parameters = Schema.object([
        "prompt": Schema.string("Detailed description of the image to create."),
        "path": Schema.string("Relative path for the image, e.g. \"Images/Neon city.png\"."),
        "aspect_ratio": Schema.string("Aspect ratio.", options: ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9"]),
        "reference_images": Schema.array("Relative paths of images in the folder to use as references (optional).", items: Schema.string("Image path"))
    ], required: ["prompt", "path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let gemini = try context.requireGemini("Image generation")
        let prompt = try args.requiredString("prompt")
        let path = try args.requiredString("path")
        let references = try args.stringArray("reference_images").prefix(6).map { try loadImageAttachment($0, context: context) }
        let model = await context.geminiModel(.image)
        let image = try await gemini.generateImage(prompt: prompt, inputs: Array(references), aspectRatio: args.optionalString("aspect_ratio"), model: model)
        let rel = try saveImage(image, to: path, context: context)
        var text = "Saved image to \(rel) (model: \(model))."
        if let caption = image.caption, !caption.isEmpty { text += " Model note: \(caption.prefix(300))" }
        return ToolOutput(text: text, files: [rel])
    }
}

struct EditImageTool: AgentTool {
    let name = "edit_image"
    let activityLabel = "Editing image"
    let description = "Edit an existing image in the JARVIS folder (or one the user attached and you saved) with natural-language instructions, e.g. remove background, change colours, add text, restyle."
    let parameters = Schema.object([
        "source_path": Schema.string("Relative path of the image to edit."),
        "instructions": Schema.string("What to change."),
        "output_path": Schema.string("Relative path for the edited image (optional; defaults to \"<name> edited.png\").")
    ], required: ["source_path", "instructions"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let gemini = try context.requireGemini("Image editing")
        let source = try args.requiredString("source_path")
        let input = try loadImageAttachment(source, context: context)
        let output = args.optionalString("output_path")
            ?? ((source as NSString).deletingPathExtension + " edited.png")
        let model = await context.geminiModel(.image)
        let image = try await gemini.generateImage(
            prompt: "Edit this image: \(try args.requiredString("instructions")). Keep everything else unchanged.",
            inputs: [input], aspectRatio: nil, model: model
        )
        let rel = try saveImage(image, to: output, context: context)
        return ToolOutput(text: "Saved edited image to \(rel).", files: [rel])
    }
}

// MARK: - PDF

struct CreatePDFTool: AgentTool {
    let name = "create_pdf"
    let activityLabel = "Typesetting PDF"
    let description = """
    Create a nicely formatted PDF document (report, letter, CV, worksheet, recipe, invoice…). Provide the body as \
    HTML (h1/h2/p/ul/ol/table/b/i are supported; inline CSS ok). Markdown or plain text also works.
    """
    let parameters = Schema.object([
        "path": Schema.string("Relative path, e.g. \"Documents/Trip itinerary.pdf\"."),
        "content": Schema.string("Document body as HTML (preferred), Markdown or plain text."),
        "title": Schema.string("Document title (optional, shown as a heading if the content has none).")
    ], required: ["path", "content"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let content = try args.requiredString("content")
        let title = args.optionalString("title")
        let url = try context.workspace.destination(for: try args.requiredString("path"), overwrite: false, defaultExtension: "pdf")
        let html = PDFMaker.html(from: content, title: title)
        let data = try await PDFMaker.render(html: html, title: title)
        try data.write(to: url)
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Created PDF \(rel).", files: [rel])
    }
}

// MARK: - Charts

private struct ChartPoint: Identifiable {
    let id: Int
    let label: String
    let value: Double
}

private struct ChartImageView: View {
    let title: String
    let type: String
    let points: [ChartPoint]
    let xLabel: String
    let yLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.black)
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Made with JARVIS")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(48)
        .frame(width: 1400, height: 900)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var chart: some View {
        switch type {
        case "pie", "donut":
            Chart(points) { point in
                SectorMark(angle: .value(yLabel, point.value), innerRadius: .ratio(type == "donut" ? 0.5 : 0), angularInset: 1.5)
                    .foregroundStyle(by: .value(xLabel, point.label))
                    .annotation(position: .overlay) {
                        Text(point.label).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    }
            }
            .chartLegend(position: .trailing)
        case "line":
            Chart(points) { point in
                LineMark(x: .value(xLabel, point.label), y: .value(yLabel, point.value))
                    .foregroundStyle(Color(red: 0.0, green: 0.55, blue: 0.85))
                    .lineStyle(StrokeStyle(lineWidth: 4))
                PointMark(x: .value(xLabel, point.label), y: .value(yLabel, point.value))
                    .foregroundStyle(Color(red: 0.0, green: 0.55, blue: 0.85))
            }
            .chartXAxisLabel(xLabel)
            .chartYAxisLabel(yLabel)
        case "area":
            Chart(points) { point in
                AreaMark(x: .value(xLabel, point.label), y: .value(yLabel, point.value))
                    .foregroundStyle(Color(red: 0.0, green: 0.55, blue: 0.85).opacity(0.5))
                LineMark(x: .value(xLabel, point.label), y: .value(yLabel, point.value))
                    .foregroundStyle(Color(red: 0.0, green: 0.45, blue: 0.75))
            }
            .chartXAxisLabel(xLabel)
            .chartYAxisLabel(yLabel)
        case "scatter":
            Chart(points) { point in
                PointMark(x: .value(xLabel, point.label), y: .value(yLabel, point.value))
                    .symbolSize(200)
                    .foregroundStyle(Color(red: 0.0, green: 0.55, blue: 0.85))
            }
            .chartXAxisLabel(xLabel)
            .chartYAxisLabel(yLabel)
        default:
            Chart(points) { point in
                BarMark(x: .value(xLabel, point.label), y: .value(yLabel, point.value))
                    .foregroundStyle(Color(red: 0.0, green: 0.55, blue: 0.85))
                    .annotation(position: .top) {
                        Text(point.value.formatted()).font(.system(size: 14)).foregroundColor(.black)
                    }
            }
            .chartXAxisLabel(xLabel)
            .chartYAxisLabel(yLabel)
        }
    }
}

struct CreateChartTool: AgentTool {
    let name = "create_chart"
    let activityLabel = "Drawing chart"
    let description = "Render a chart (bar, line, area, pie, donut, scatter) as a PNG image in the JARVIS folder."
    let parameters = Schema.object([
        "path": Schema.string("Relative path, e.g. \"Charts/Monthly spending.png\"."),
        "title": Schema.string("Chart title."),
        "chart_type": Schema.string("Kind of chart.", options: ["bar", "line", "area", "pie", "donut", "scatter"]),
        "labels": Schema.array("Category labels (x axis / slices).", items: Schema.string("Label")),
        "values": Schema.array("Numeric values, same order as labels.", items: Schema.number("Value")),
        "x_label": Schema.string("X axis / category name (optional)."),
        "y_label": Schema.string("Y axis / value name (optional).")
    ], required: ["path", "title", "chart_type", "labels", "values"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let labels = args.stringArray("labels")
        let values = (args["values"]?.arrayValue ?? []).compactMap(\.doubleValue)
        guard !labels.isEmpty, labels.count == values.count else {
            throw ToolError.invalid("labels and values must be non-empty and the same length.")
        }
        let points = zip(labels, values).enumerated().map { ChartPoint(id: $0.offset, label: $0.element.0, value: $0.element.1) }
        let view = ChartImageView(
            title: try args.requiredString("title"),
            type: args.optionalString("chart_type") ?? "bar",
            points: points,
            xLabel: args.optionalString("x_label") ?? "Category",
            yLabel: args.optionalString("y_label") ?? "Value"
        )
        let png: Data? = await MainActor.run {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return nil }
            return ImageCoder.encode(image, type: .png)
        }
        guard let png else { throw ToolError.invalid("Could not render the chart.") }
        let url = try context.workspace.destination(for: try args.requiredString("path"), overwrite: false, defaultExtension: "png")
        try png.write(to: url)
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Saved chart to \(rel).", files: [rel])
    }
}

// MARK: - QR code

struct CreateQRCodeTool: AgentTool {
    let name = "create_qr_code"
    let activityLabel = "Making QR code"
    let description = "Create a QR code PNG for a URL, Wi-Fi login (WIFI:T:WPA;S:name;P:pass;;), contact or any text."
    let parameters = Schema.object([
        "text": Schema.string("Text or URL to encode."),
        "path": Schema.string("Relative path, e.g. \"QR/Website.png\".")
    ], required: ["text", "path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(try args.requiredString("text").utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw ToolError.invalid("Could not create the QR code.") }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 24, y: 24))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent),
              let png = ImageCoder.encode(cgImage, type: .png) else {
            throw ToolError.invalid("Could not render the QR code.")
        }
        let url = try context.workspace.destination(for: try args.requiredString("path"), overwrite: false, defaultExtension: "png")
        try png.write(to: url)
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Saved QR code to \(rel).", files: [rel])
    }
}

// MARK: - Speech audio files

struct TextToSpeechTool: AgentTool {
    let name = "text_to_speech"
    let activityLabel = "Recording audio"
    let description = """
    Turn text into a spoken audio file (WAV) – narrations, voice notes, bedtime stories, pronunciations. \
    Uses Gemini voices (e.g. Charon, Kore, Puck, Zephyr, Fenrir, Aoede, Leda, Orus) or the device voice if no Gemini key.
    """
    let parameters = Schema.object([
        "text": Schema.string("What to say."),
        "path": Schema.string("Relative path, e.g. \"Audio/Story.wav\"."),
        "voice": Schema.string("Gemini voice name (optional)."),
        "style": Schema.string("Delivery instructions, e.g. \"Say warmly and slowly\" (optional).")
    ], required: ["text", "path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let text = try args.requiredString("text")
        let path = try args.requiredString("path")
        if let gemini = context.gemini {
            let model = await context.geminiModel(.tts)
            let voice = args.optionalString("voice") ?? context.settings.geminiVoiceName
            let wav = try await gemini.synthesizeSpeech(text: text, voice: voice, style: args.optionalString("style"), model: model)
            let wavPath = (path as NSString).deletingPathExtension + ".wav"
            let url = try context.workspace.destination(for: wavPath, overwrite: false)
            try wav.write(to: url)
            let rel = context.workspace.relativePath(of: url)
            return ToolOutput(text: "Saved audio to \(rel) (voice \(voice)).", files: [rel])
        }
        // Offline fallback: the system voice.
        let cafPath = (path as NSString).deletingPathExtension + ".caf"
        let url = try context.workspace.destination(for: cafPath, overwrite: false)
        try await SpeechFileWriter.write(text: text, to: url, voiceIdentifier: context.settings.voiceIdentifier)
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Saved audio to \(rel) using the device voice.", files: [rel])
    }
}

/// Renders AVSpeechSynthesizer output into an audio file.
final class SpeechFileWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private let url: URL

    private init(url: URL) {
        self.url = url
        super.init()
        synthesizer.delegate = self
    }

    static func write(text: String, to url: URL, voiceIdentifier: String) async throws {
        let writer = SpeechFileWriter(url: url)
        try await writer.run(text: text, voiceIdentifier: voiceIdentifier)
    }

    private func run(text: String, voiceIdentifier: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? VoiceOutput.bestVoice(for: text)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { self.finish(nil); return }
                do {
                    if self.file == nil {
                        self.file = try AVAudioFile(forWriting: self.url, settings: pcm.format.settings,
                                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try self.file?.write(from: pcm)
                } catch {
                    self.finish(error)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    private func finish(_ error: Error?) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard !finished else { return }
        finished = true
        file = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish(nil) }
    }
}
