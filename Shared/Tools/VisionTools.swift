import Foundation
import Vision
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// On-device text recognition (Live Text).
enum OCR {
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func cgImage(for page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height, 1)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        #if os(iOS)
        return thumbnail.cgImage
        #else
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

struct ExtractTextTool: AgentTool {
    let name = "extract_text"
    let activityLabel = "Reading text"
    let description = "Read the text in a photo, screenshot or scanned PDF from the JARVIS folder using fast on-device OCR. Optionally save it as a .txt file."
    let parameters = Schema.object([
        "path": Schema.string("Relative path of the image or PDF."),
        "save_as": Schema.string("Optional relative .txt path to save the text to.")
    ], required: ["path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try args.requiredString("path")
        let url = try context.workspace.resolve(raw)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(raw) }
        var text = ""
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw ToolError.invalid("Couldn't open the PDF.") }
            let embedded = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if embedded.count > 20 {
                text = embedded
            } else {
                var pages: [String] = []
                for index in 0..<min(document.pageCount, 20) {
                    if let page = document.page(at: index), let image = OCR.cgImage(for: page) {
                        pages.append(try OCR.recognize(image))
                    }
                }
                text = pages.enumerated().map { "— Page \($0.offset + 1) —\n\($0.element)" }.joined(separator: "\n\n")
            }
        } else {
            guard let image = ImageCoder.thumbnail(url: url, maxPixel: 3000) else { throw ToolError.invalid("\(raw) isn't a readable image.") }
            text = try OCR.recognize(image)
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ToolOutput(text: "No text found in \(raw).") }
        if let savePath = args.optionalString("save_as") {
            let destination = try context.workspace.destination(for: savePath, overwrite: false, defaultExtension: "txt")
            try text.write(to: destination, atomically: true, encoding: .utf8)
            let rel = context.workspace.relativePath(of: destination)
            return ToolOutput(text: "Saved the text to \(rel):\n\(text.prefix(20_000))", files: [rel])
        }
        return ToolOutput(text: String(text.prefix(30_000)))
    }
}
