import Foundation

/// Uses the user's Claude Pro/Max subscription through the official Claude Code
/// CLI (`claude -p`). The CLI keeps the conversation history itself, so each
/// turn only sends the newest user message and resumes the session.
struct ClaudeCodeProvider: LLMProvider {
    let settings: AppSettings
    let workspace: Workspace

    var kind: ProviderKind { .claudeCode }
    var modelName: String { settings.claudeCodeModel.isEmpty ? "Claude Code" : "Claude Code (\(settings.claudeCodeModel))" }

    static let candidatePaths = [
        "~/.claude/local/claude",
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.bun/bin/claude"
    ]

    /// Finds the `claude` executable (custom path, common locations, then PATH).
    static func locateCLI(customPath: String) -> String {
        let fm = FileManager.default
        if !customPath.isEmpty {
            return (customPath as NSString).expandingTildeInPath
        }
        for candidate in candidatePaths {
            let path = (candidate as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return "claude" // resolved through the login shell's PATH
    }

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        guard let lastUser = request.messages.last(where: { $0.role == .user }) else {
            throw LLMError.invalidResponse("nothing to send")
        }

        // Write attachments (incl. screenshots) to files Claude Code can Read.
        let attachmentsFolder = workspace.internalFolder.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        var prompt = lastUser.parts.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
        var attachmentLines: [String] = []
        for attachment in lastUser.attachments {
            let ext = (attachment.name as NSString).pathExtension.isEmpty ? "bin" : (attachment.name as NSString).pathExtension
            let url = attachmentsFolder.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try attachment.data.write(to: url)
            attachmentLines.append("- \(attachment.name): \(url.path)")
        }
        if !attachmentLines.isEmpty {
            prompt += "\n\nAttached files (use the Read tool to view them; images are screenshots/photos from the user):\n"
                + attachmentLines.joined(separator: "\n")
        }

        var tools = ["Read", "Write", "Edit", "Glob", "Grep", "WebSearch", "WebFetch"]
        if settings.claudeCodeAllowBash { tools.append("Bash") }
        var arguments = [
            "-p",
            "--output-format", "json",
            "--permission-mode", "acceptEdits",
            "--allowedTools", tools.joined(separator: " "),
            "--append-system-prompt", request.system
        ]
        if !settings.claudeCodeModel.isEmpty { arguments += ["--model", settings.claudeCodeModel] }
        if let session = request.sessionID, !session.isEmpty { arguments += ["--resume", session] }

        let executable = ClaudeCodeProvider.locateCLI(customPath: settings.claudeCodePath)
        let result = try await ProcessRunner.shell(
            "exec \"$JARVIS_CLAUDE\" \"$@\"",
            input: prompt,
            currentDirectory: workspace.root,
            timeout: 900,
            environment: ["JARVIS_CLAUDE": executable],
            arguments: arguments
        )

        if result.timedOut { throw LLMError.unavailable("Claude Code took too long (15 min) and was stopped.") }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = (try? JSONValue.parse(output)) ?? JSONValue.extractObject(from: output) else {
            if result.stderr.contains("command not found") || result.status == 127 {
                throw LLMError.unavailable("Claude Code CLI not found. Install it (npm install -g @anthropic-ai/claude-code, or the native installer), run `claude` once in Terminal to log in, or set its path in Settings.")
            }
            let detail = (result.stderr.isEmpty ? output : result.stderr).prefix(600)
            throw LLMError.unavailable("Claude Code failed (exit \(result.status)): \(detail)")
        }
        let text = json["result"]?.stringValue ?? ""
        if json["is_error"]?.boolValue == true {
            throw LLMError.unavailable("Claude Code: \(text.isEmpty ? (json["subtype"]?.stringValue ?? "error") : text)")
        }
        return LLMReply(
            parts: [.text(text.isEmpty ? "(Claude Code finished without a text reply.)" : text)],
            raw: nil,
            model: "claude-code",
            stopReason: json["subtype"]?.stringValue,
            sessionID: json["session_id"]?.stringValue
        )
    }

    /// Quick health check used by Settings.
    static func checkInstallation(customPath: String) async -> String {
        let executable = locateCLI(customPath: customPath)
        do {
            let result = try await ProcessRunner.shell("exec \"$JARVIS_CLAUDE\" --version", timeout: 30,
                                                       environment: ["JARVIS_CLAUDE": executable])
            if result.status == 0 { return "✅ Found Claude Code \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))" }
            return "❌ \(result.stderr.isEmpty ? "Claude Code not found." : result.stderr)"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }
}
