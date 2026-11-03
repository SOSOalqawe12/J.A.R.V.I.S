import Foundation

/// Tool calling for models without native function calling (many local models,
/// Apple's on-device model): tools are described in the prompt and the model
/// answers with `<tool_call>{"name": …, "arguments": {…}}</tool_call>` blocks
/// (the Hermes/Qwen convention most open models are trained on).
enum PromptedTools {
    static func instructions(for tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        let lines = tools.map { tool -> String in
            let properties = tool.parameters["properties"]?.objectValue ?? [:]
            let required = Set((tool.parameters["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            let params = properties.keys.sorted().map { key -> String in
                let type = properties[key]?["type"]?.stringValue ?? "string"
                return "\(key)\(required.contains(key) ? "" : "?"): \(type)"
            }.joined(separator: ", ")
            let summary = tool.description.components(separatedBy: ". ").first ?? tool.description
            return "- \(tool.name)(\(params)): \(summary.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return """
        # Tools
        You can use these tools. To call one, reply with exactly this format (you may include several):
        <tool_call>{"name": "tool_name", "arguments": {"param": "value"}}</tool_call>
        Then stop and wait: the results come back in a <tool_response> message. Never invent results.
        \(lines.joined(separator: "\n"))
        """
    }

    /// Splits model text into visible text and tool calls.
    static func extract(_ text: String) -> (text: String, calls: [ToolCall]) {
        guard text.contains("<tool_call>") else { return (text, []) }
        var calls: [ToolCall] = []
        var visible = text
        let pattern = "(?s)<tool_call>\\s*(.*?)\\s*</tool_call>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let body = nsText.substring(with: match.range(at: 1))
            guard let json = (try? JSONValue.parse(body)) ?? JSONValue.extractObject(from: body),
                  let name = json["name"]?.stringValue else { continue }
            var arguments = json["arguments"] ?? json["parameters"] ?? [:]
            if let string = arguments.stringValue, let parsed = try? JSONValue.parse(string) { arguments = parsed }
            calls.append(ToolCall(id: ToolCall.makeLocalID(), name: name, arguments: arguments))
        }
        visible = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: "")
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    static func render(_ call: ToolCall) -> String {
        let payload: JSONValue = ["name": .string(call.name), "arguments": call.arguments]
        return "<tool_call>\(payload.jsonString())</tool_call>"
    }

    static func render(_ result: ToolResult) -> String {
        "<tool_response name=\"\(result.name)\">\n\(result.isError ? "ERROR: " : "")\(result.output)\n</tool_response>"
    }

    /// Removes `<think>…</think>` reasoning that some local models emit.
    static func stripReasoning(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if let open = result.range(of: "<think>"), result.range(of: "</think>") == nil {
            result = String(result[..<open.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A compact plain-text transcript (for models that take a single prompt).
    static func transcript(_ messages: [ChatMessage], characterBudget: Int) -> String {
        var lines: [String] = []
        for message in messages where !message.isLocalNotice {
            switch message.role {
            case .user:
                var text = message.parts.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
                for attachment in message.attachments {
                    if attachment.isText, let body = String(data: attachment.data, encoding: .utf8) {
                        text += "\n[Attached \(attachment.name)]\n\(body.prefix(4000))"
                    } else {
                        text += "\n[Attached \(attachment.name) – not readable by this model]"
                    }
                }
                lines.append("User: \(text)")
            case .assistant:
                var text = message.visibleText
                for call in message.toolCalls { text += "\n" + render(call) }
                lines.append("Assistant: \(text)")
            case .tool:
                lines.append(message.toolResults.map(render).joined(separator: "\n"))
            }
        }
        var output = ""
        for line in lines.reversed() {
            if output.count + line.count > characterBudget { break }
            output = line + "\n\n" + output
        }
        return output
    }
}
