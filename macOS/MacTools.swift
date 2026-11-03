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
            ShowNotificationTool()
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
