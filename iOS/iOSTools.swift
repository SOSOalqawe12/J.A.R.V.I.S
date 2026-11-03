import Foundation
import Photos
import UIKit

enum iOSTools {
    static var all: [AgentTool] { [SaveToPhotosTool(), OpenURLTool()] }
}

enum PhotoLibrary {
    /// Saves an image or video file into the user's Photos library (add-only permission).
    static func save(imageAt url: URL) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ToolError.invalid("Photos access was not granted. Enable it in Settings › JARVIS › Photos.")
        }
        let isVideo = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
        try await PHPhotoLibrary.shared().performChanges {
            if isVideo {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }
        return true
    }
}

struct SaveToPhotosTool: AgentTool {
    let name = "save_to_photos"
    let activityLabel = "Saving to Photos"
    let description = "Save an image (or video) from the JARVIS folder into the user's Photos library."
    let parameters = Schema.object(["path": Schema.string("Relative path of the image in the JARVIS folder.")], required: ["path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try args.requiredString("path")
        let url = try context.workspace.resolve(raw)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(raw) }
        _ = try await PhotoLibrary.save(imageAt: url)
        return ToolOutput(text: "Saved \(url.lastPathComponent) to Photos.")
    }
}

struct OpenURLTool: AgentTool {
    let name = "open_url"
    let activityLabel = "Opening"
    let description = "Open a URL on the iPhone: websites, maps (maps://?q=), phone (tel:), messages (sms:), email (mailto:), or other apps' links."
    let parameters = Schema.object(["url": Schema.string("The URL to open.")], required: ["url"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try args.requiredString("url")
        guard let url = URL(string: raw) else { throw ToolError.invalid("Invalid URL.") }
        if ["tel", "sms", "mailto", "facetime"].contains(url.scheme?.lowercased() ?? "") {
            try await context.approve("Open \(url.scheme ?? "link")?", detail: raw)
        }
        let opened = await UIApplication.shared.open(url)
        return ToolOutput(text: opened ? "Opened \(raw)." : "iOS couldn't open \(raw).")
    }
}
