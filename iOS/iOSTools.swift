import Foundation
import Photos
import UIKit
import MessageUI
import MediaPlayer
import UniformTypeIdentifiers
import SwiftUI

enum iOSTools {
    static var all: [AgentTool] {
        [SaveToPhotosTool(), OpenURLTool(), ComposeEmailTool(), ComposeMessageTool(), MusicControlTool(), RunShortcutTool(), FindContactTool()]
    }
}

/// Presents system sheets (Mail, Messages, Share) from tools.
@MainActor
final class SheetPresenter: NSObject, MFMailComposeViewControllerDelegate, MFMessageComposeViewControllerDelegate {
    static let shared = SheetPresenter()
    private var continuation: CheckedContinuation<String, Never>?

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func present(_ controller: UIViewController) async -> String {
        guard UIApplication.shared.applicationState == .active, let top = SheetPresenter.topViewController() else {
            return "JARVIS needs to be open on screen to show this."
        }
        return await withCheckedContinuation { continuation in
            self.continuation?.resume(returning: "Cancelled.")
            self.continuation = continuation
            top.present(controller, animated: true)
        }
    }

    private func finish(_ text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }

    func composeMail(to: [String], subject: String, body: String, attachments: [URL]) async -> String {
        guard MFMailComposeViewController.canSendMail() else {
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = to.joined(separator: ",")
            components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = components.url, await UIApplication.shared.open(url) {
                return "Opened a draft in your mail app" + (attachments.isEmpty ? "." : " (attachments need Apple Mail – share the files from the Files tab).")
            }
            return "No mail account is set up on this device."
        }
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = self
        controller.setToRecipients(to)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        for url in attachments {
            if let data = try? Data(contentsOf: url) {
                controller.addAttachmentData(data, mimeType: Workspace.mimeType(for: url), fileName: url.lastPathComponent)
            }
        }
        return await present(controller)
    }

    func composeMessage(to: [String], body: String, attachments: [URL]) async -> String {
        guard MFMessageComposeViewController.canSendText() else { return "This device can't send messages." }
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = self
        controller.recipients = to
        controller.body = body
        if MFMessageComposeViewController.canSendAttachments() {
            for url in attachments {
                if let data = try? Data(contentsOf: url) {
                    let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
                    controller.addAttachmentData(data, typeIdentifier: type, filename: url.lastPathComponent)
                }
            }
        }
        return await present(controller)
    }

    func share(_ urls: [URL]) async -> String {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak self] activity, completed, _, _ in
            Task { @MainActor in self?.finish(completed ? "Shared via \(activity?.rawValue ?? "share sheet")." : "Sharing cancelled.") }
        }
        if let popover = controller.popoverPresentationController, let view = SheetPresenter.topViewController()?.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        return await present(controller)
    }

    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let text: String
        switch result {
        case .sent: text = "The email was sent."
        case .saved: text = "The email was saved as a draft."
        case .cancelled: text = "The user cancelled the email."
        default: text = "The email couldn't be sent\(error.map { ": \($0.localizedDescription)" } ?? ".")"
        }
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.finish(text)
        }
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let text: String
        switch result {
        case .sent: text = "The message was sent."
        case .cancelled: text = "The user cancelled the message."
        default: text = "The message couldn't be sent."
        }
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.finish(text)
        }
    }
}

private func attachmentURLs(_ args: JSONValue, context: ToolContext) throws -> [URL] {
    try args.stringArray("attachments").map { path in
        let url = try context.workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(path) }
        return url
    }
}

struct ComposeEmailTool: AgentTool {
    let name = "compose_email"
    let activityLabel = "Writing email"
    let description = "Open a ready-to-send email (the user reviews and taps Send), optionally attaching files from the JARVIS folder. Use find_contact to get addresses."
    let parameters = Schema.object([
        "to": Schema.array("Recipient email addresses.", items: Schema.string("Email")),
        "subject": Schema.string("Subject line."),
        "body": Schema.string("Email text."),
        "attachments": Schema.array("Relative paths of files to attach (optional).", items: Schema.string("Path"))
    ], required: ["subject", "body"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let urls = try attachmentURLs(args, context: context)
        let result = await SheetPresenter.shared.composeMail(
            to: args.stringArray("to"), subject: try args.requiredString("subject"), body: try args.requiredString("body"), attachments: urls)
        return ToolOutput(text: result)
    }
}

struct ComposeMessageTool: AgentTool {
    let name = "compose_message"
    let activityLabel = "Writing message"
    let description = "Open a ready-to-send iMessage/SMS (the user taps Send), optionally with files from the JARVIS folder. Use find_contact for phone numbers."
    let parameters = Schema.object([
        "to": Schema.array("Phone numbers or iMessage emails.", items: Schema.string("Recipient")),
        "body": Schema.string("Message text."),
        "attachments": Schema.array("Relative paths of files to attach (optional).", items: Schema.string("Path"))
    ], required: ["body"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let urls = try attachmentURLs(args, context: context)
        let result = await SheetPresenter.shared.composeMessage(to: args.stringArray("to"), body: try args.requiredString("body"), attachments: urls)
        return ToolOutput(text: result)
    }
}

struct MusicControlTool: AgentTool {
    let name = "control_music"
    let activityLabel = "Controlling music"
    let description = "Control the Music app: play, pause, skip, what's playing, or play songs from the user's library matching an artist, song or album."
    let parameters = Schema.object([
        "action": Schema.string("What to do.", options: ["play", "pause", "toggle", "next", "previous", "now_playing", "play_search", "shuffle_all"]),
        "query": Schema.string("Artist, song or album for play_search.")
    ], required: ["action"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let action = args.optionalString("action") ?? "toggle"
        let query = args.optionalString("query") ?? ""
        if action == "play_search" || action == "shuffle_all" {
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw ToolError.invalid("Media library access isn't allowed. Enable it in Settings › JARVIS.") }
        }
        let text: String = await MainActor.run {
            let player = MPMusicPlayerController.systemMusicPlayer
            switch action {
            case "play": player.play(); return "Playing."
            case "pause": player.pause(); return "Paused."
            case "toggle":
                if player.playbackState == .playing { player.pause(); return "Paused." }
                player.play(); return "Playing."
            case "next": player.skipToNextItem(); return "Skipped to the next track."
            case "previous": player.skipToPreviousItem(); return "Back to the previous track."
            case "now_playing":
                guard let item = player.nowPlayingItem else { return "Nothing is playing." }
                return "Now playing: \(item.title ?? "Unknown") – \(item.artist ?? "Unknown artist")" + (item.albumTitle.map { " (\($0))" } ?? "")
            case "shuffle_all":
                let items = MPMediaQuery.songs().items ?? []
                guard !items.isEmpty else { return "Your music library is empty." }
                player.shuffleMode = .songs
                player.setQueue(with: MPMediaItemCollection(items: items))
                player.play()
                return "Shuffling your library (\(items.count) songs)."
            default:
                let needle = query.lowercased()
                guard !needle.isEmpty else { return "Tell me what to play." }
                let matches = (MPMediaQuery.songs().items ?? []).filter { item in
                    [item.title, item.artist, item.albumTitle].compactMap { $0?.lowercased() }.contains { $0.contains(needle) }
                }
                guard !matches.isEmpty else { return "Nothing in your library matches \"\(query)\". (Streaming-only Apple Music songs can't be searched.)" }
                player.setQueue(with: MPMediaItemCollection(items: Array(matches.prefix(200))))
                player.play()
                return "Playing \(matches.count) song(s) matching \"\(query)\"."
            }
        }
        return ToolOutput(text: text)
    }
}

/// Share sheet for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
