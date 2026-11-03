import Foundation
import AppKit
import UserNotifications

enum MacTools {
    static var all: [AgentTool] {
        [
            CaptureScreenTool(),
            FrontmostAppTool(),
            RunShellTool(),
            RunAppleScriptTool(),
            OpenURLMacTool(),
            OpenAppTool(),
            RevealInFinderTool(),
            ShowNotificationTool(),
            RunShortcutTool(),
            ListShortcutsTool(),
            FindContactTool(),
            ComposeEmailTool(),
            ComposeMessageTool(),
            MusicControlTool()
        ]
    }
}

enum MacNotifier {
    static func post(title: String, body: String) async {
        await Notifier.post(title: title, body: body)
    }
}

private func truncate(_ text: String, _ limit: Int = 15_000) -> String {
    text.count > limit ? String(text.prefix(limit)) + "\n…[truncated]" : text
}

struct CaptureScreenTool: AgentTool {
    let name = "capture_screen"
    let activityLabel = "Looking at your screen"
    let description = "Take a fresh screenshot of the user's screen (the display with the mouse) so you can see what they see."
    let parameters = Schema.object([:])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let attachment = try await ScreenCapture.captureAttachment()
        let front = await ScreenCapture.contextLine() ?? ""
        return ToolOutput(text: "Screenshot attached. \(front)", images: [attachment])
    }
}

struct FrontmostAppTool: AgentTool {
    let name = "frontmost_app"
    let activityLabel = "Checking apps"
    let description = "Get the app and window the user is currently using, plus the list of open apps."
    let parameters = Schema.object([:])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let text: String = await MainActor.run {
            let front = ScreenCapture.frontmost()
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
            var lines: [String] = []
            if let front {
                lines.append("Frontmost: \(front.appName) (\(front.bundleID))")
                if let title = front.windowTitle, !title.isEmpty { lines.append("Window: \(title)") }
            }
            lines.append("Open apps: " + running.joined(separator: ", "))
            return lines.joined(separator: "\n")
        }
        return ToolOutput(text: text)
    }
}

struct RunShellTool: AgentTool {
    let name = "run_shell_command"
    let activityLabel = "Running command"
    let description = """
    Run a zsh command on the user's Mac (working directory: the JARVIS folder) and return its output. \
    The user must approve it. Use for file conversions, system info, git, homebrew, scripts, etc.
    """
    let parameters = Schema.object([
        "command": Schema.string("The shell command."),
        "reason": Schema.string("One sentence on why, shown to the user."),
        "timeout_seconds": Schema.integer("Max run time (default 120, max 600).")
    ], required: ["command"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let command = try args.requiredString("command")
        let reason = args.optionalString("reason") ?? ""
        try await context.approve("Run a Terminal command?", detail: "\(reason)\n\n$ \(command)")
        let timeout = TimeInterval(min(max(args.int("timeout_seconds") ?? 120, 5), 600))
        let result = try await ProcessRunner.shell(command, currentDirectory: context.workspace.root, timeout: timeout)
        var text = "Exit code \(result.status)\(result.timedOut ? " (timed out)" : "")\n" + truncate(result.combined)
        if result.combined.isEmpty { text += "(no output)" }
        return ToolOutput(text: text)
    }
}

struct RunAppleScriptTool: AgentTool {
    let name = "run_applescript"
    let activityLabel = "Running AppleScript"
    let description = """
    Run AppleScript to control Mac apps (Safari, Notes, Mail, Calendar, Reminders, Music, Finder, System Events…). \
    The user must approve it. Returns the script result.
    """
    let parameters = Schema.object([
        "script": Schema.string("The AppleScript source."),
        "reason": Schema.string("One sentence on what it does, shown to the user.")
    ], required: ["script"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let script = try args.requiredString("script")
        let reason = args.optionalString("reason") ?? ""
        try await context.approve("Run an AppleScript?", detail: "\(reason)\n\n\(script)")
        let result = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-"], input: script, timeout: 120)
        if result.status != 0 {
            return ToolOutput(text: "AppleScript error (\(result.status)): \(truncate(result.stderr))")
        }
        return ToolOutput(text: result.stdout.isEmpty ? "Done (no result)." : truncate(result.stdout))
    }
}

struct OpenURLMacTool: AgentTool {
    let name = "open_url"
    let activityLabel = "Opening"
    let description = "Open a URL in the default browser or app (http(s), mailto:, maps:, x-apple.systempreferences:, app deep links)."
    let parameters = Schema.object(["url": Schema.string("The URL to open.")], required: ["url"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try args.requiredString("url")
        guard let url = URL(string: raw), url.scheme != nil else { throw ToolError.invalid("Invalid URL.") }
        if !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            try await context.approve("Open \(url.scheme ?? "") link?", detail: raw)
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return ToolOutput(text: opened ? "Opened \(raw)." : "macOS couldn't open \(raw).")
    }
}

struct OpenAppTool: AgentTool {
    let name = "open_app"
    let activityLabel = "Opening app"
    let description = "Launch or switch to a Mac app by name (e.g. \"Safari\", \"Notes\", \"Visual Studio Code\"), optionally opening a file from the JARVIS folder in it."
    let parameters = Schema.object([
        "app": Schema.string("Application name."),
        "file_path": Schema.string("Optional relative path in the JARVIS folder to open with the app.")
    ], required: ["app"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let app = try args.requiredString("app")
        var arguments = ["-a", app]
        if let path = args.optionalString("file_path") {
            arguments.append(try context.workspace.resolve(path).path)
        }
        let result = try await ProcessRunner.run("/usr/bin/open", arguments: arguments, timeout: 30)
        return ToolOutput(text: result.status == 0 ? "Opened \(app)." : "Couldn't open \(app): \(result.stderr)")
    }
}

struct RevealInFinderTool: AgentTool {
    let name = "reveal_in_finder"
    let activityLabel = "Showing in Finder"
    let description = "Show a file or folder from the JARVIS folder in Finder."
    let parameters = Schema.object(["path": Schema.string("Relative path (empty for the JARVIS folder itself).")])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try context.workspace.resolve(args.optionalString("path") ?? "")
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return ToolOutput(text: "Showing \(context.workspace.relativePath(of: url)) in Finder.")
    }
}

struct ShowNotificationTool: AgentTool {
    let name = "show_notification"
    let activityLabel = "Notifying"
    let description = "Show a macOS notification (e.g. a reminder or a finished task)."
    let parameters = Schema.object([
        "title": Schema.string("Notification title."),
        "body": Schema.string("Notification text.")
    ], required: ["title", "body"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let title = try args.requiredString("title")
        let body = try args.requiredString("body")
        await MacNotifier.post(title: title, body: body)
        return ToolOutput(text: "Notification shown.")
    }
}

struct ListShortcutsTool: AgentTool {
    let name = "list_shortcuts"
    let activityLabel = "Listing shortcuts"
    let description = "List the names of the user's Shortcuts (to find one to run with run_shortcut)."
    let parameters = Schema.object([:])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let result = try await ProcessRunner.run("/usr/bin/shortcuts", arguments: ["list"], timeout: 30)
        let names = result.stdout.split(separator: "\n").map(String.init)
        return ToolOutput(text: names.isEmpty ? "No shortcuts found." : "\(names.count) shortcuts:\n" + names.joined(separator: "\n"))
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
    let description = "Open a ready-to-send email in Mail (the user reviews and clicks Send), optionally attaching files from the JARVIS folder."
    let parameters = Schema.object([
        "to": Schema.array("Recipient email addresses.", items: Schema.string("Email")),
        "subject": Schema.string("Subject line."),
        "body": Schema.string("Email text."),
        "attachments": Schema.array("Relative paths of files to attach (optional).", items: Schema.string("Path"))
    ], required: ["subject", "body"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let urls = try attachmentURLs(args, context: context)
        let to = args.stringArray("to")
        let subject = try args.requiredString("subject")
        let body = try args.requiredString("body")
        let ok: Bool = await MainActor.run {
            guard let service = NSSharingService(named: .composeEmail) else { return false }
            service.recipients = to
            service.subject = subject
            let items: [Any] = [body as NSString] + urls.map { $0 as NSURL }
            guard service.canPerform(withItems: items) else { return false }
            service.perform(withItems: items)
            return true
        }
        return ToolOutput(text: ok ? "Opened the email draft in Mail." : "Couldn't open Mail – is an account set up?")
    }
}

struct ComposeMessageTool: AgentTool {
    let name = "compose_message"
    let activityLabel = "Writing message"
    let description = "Open a ready-to-send iMessage in Messages (the user clicks Send), optionally with files."
    let parameters = Schema.object([
        "to": Schema.array("Phone numbers or iMessage emails.", items: Schema.string("Recipient")),
        "body": Schema.string("Message text."),
        "attachments": Schema.array("Relative paths of files to attach (optional).", items: Schema.string("Path"))
    ], required: ["body"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let urls = try attachmentURLs(args, context: context)
        let to = args.stringArray("to")
        let body = try args.requiredString("body")
        let ok: Bool = await MainActor.run {
            guard let service = NSSharingService(named: .composeMessage) else { return false }
            service.recipients = to
            let items: [Any] = [body as NSString] + urls.map { $0 as NSURL }
            guard service.canPerform(withItems: items) else { return false }
            service.perform(withItems: items)
            return true
        }
        return ToolOutput(text: ok ? "Opened the message in Messages." : "Couldn't open Messages.")
    }
}

struct MusicControlTool: AgentTool {
    let name = "control_music"
    let activityLabel = "Controlling music"
    let description = "Control the Music app: play, pause, skip, what's playing, or play library songs matching an artist, song or album."
    let parameters = Schema.object([
        "action": Schema.string("What to do.", options: ["play", "pause", "toggle", "next", "previous", "now_playing", "play_search", "shuffle_all"]),
        "query": Schema.string("Artist, song or album for play_search.")
    ], required: ["action"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let action = args.optionalString("action") ?? "toggle"
        let query = (args.optionalString("query") ?? "").replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let script: String
        switch action {
        case "play": script = "tell application \"Music\" to play"
        case "pause": script = "tell application \"Music\" to pause"
        case "toggle": script = "tell application \"Music\" to playpause"
        case "next": script = "tell application \"Music\" to next track"
        case "previous": script = "tell application \"Music\" to previous track"
        case "now_playing":
            script = "tell application \"Music\" to if player state is playing then return (name of current track) & \" – \" & (artist of current track)\nreturn \"Nothing is playing.\""
        case "shuffle_all":
            script = "tell application \"Music\"\nset shuffle enabled to true\nplay library playlist 1\nend tell"
        default:
            script = "tell application \"Music\" to play (first track of library playlist 1 whose name contains \"\(query)\" or artist contains \"\(query)\" or album contains \"\(query)\")"
        }
        let result = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-"], input: script, timeout: 30)
        if result.status != 0 { return ToolOutput(text: "Music couldn't do that: \(result.stderr.prefix(300))") }
        return ToolOutput(text: result.stdout.isEmpty ? "Done." : result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
