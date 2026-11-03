import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let activityLabel = "Searching the web"
    let description = "Search the internet for current information (news, prices, weather, facts, how-tos). Returns a summary with sources."
    let parameters = Schema.object(["query": Schema.string("What to search for.")], required: ["query"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try args.requiredString("query")
        if let gemini = context.gemini {
            let model = await context.geminiModel(.chat)
            return ToolOutput(text: try await gemini.groundedSearch(query, model: model))
        }
        if context.settings.hasClaudeKey {
            let client = ClaudeClient(apiKey: context.settings.claudeAPIKey)
            return ToolOutput(text: try await client.webSearch(query, model: context.settings.claudeModel))
        }
        // No key needed: DuckDuckGo results (use fetch_url to read a page).
        let results = try await DuckDuckGo.search(query)
        if results.isEmpty { return ToolOutput(text: "No results found for \"\(query)\".") }
        let lines = results.prefix(8).enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\n   \($0.element.snippet)" }
        return ToolOutput(text: "Search results for \"\(query)\" (open one with fetch_url for details):\n" + lines.joined(separator: "\n"))
    }
}

enum DuckDuckGo {
    struct Result: Hashable {
        let title: String
        let url: String
        let snippet: String
    }

    static func search(_ query: String) async throws -> [Result] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await HTTP.session.data(for: request)
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ html: String) -> [Result] {
        html.components(separatedBy: "class=\"result__a\"").dropFirst().compactMap { chunk in
            guard var link = firstMatch("href=\"([^\"]+)\"", in: chunk),
                  let rawTitle = firstMatch("(?s)>(.*?)</a>", in: chunk) else { return nil }
            link = link.replacingOccurrences(of: "&amp;", with: "&")
            if let components = URLComponents(string: link.hasPrefix("//") ? "https:" + link : link),
               let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                link = target
            }
            let title = WebText.plainText(fromHTML: rawTitle)
            guard !title.isEmpty, link.hasPrefix("http") else { return nil }
            let snippet = firstMatch("(?s)class=\"result__snippet\"[^>]*>(.*?)</a>", in: chunk).map(WebText.plainText(fromHTML:)) ?? ""
            return Result(title: title, url: link, snippet: snippet)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

struct FetchURLTool: AgentTool {
    let name = "fetch_url"
    let activityLabel = "Reading web page"
    let description = "Download a web page or text/JSON URL and return its readable text."
    let parameters = Schema.object([
        "url": Schema.string("The http(s) URL."),
        "max_characters": Schema.integer("Maximum characters to return (default 20000).")
    ], required: ["url"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let url = URL(string: try args.requiredString("url")), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw ToolError.invalid("Please provide a valid http(s) URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (JARVIS assistant)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.session.data(for: request)
        let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
        let limit = args.int("max_characters") ?? 20_000
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = mime.contains("html") || raw.lowercased().contains("<html") ? WebText.plainText(fromHTML: raw) : raw
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ToolOutput(text: "HTTP \(status) \(url.absoluteString)\n\n" + String(text.prefix(limit)))
    }
}

struct DownloadFileTool: AgentTool {
    let name = "download_file"
    let activityLabel = "Downloading"
    let description = "Download a file (image, PDF, document…) from a URL into the JARVIS folder."
    let parameters = Schema.object([
        "url": Schema.string("The http(s) URL to download."),
        "path": Schema.string("Relative destination path, e.g. \"Downloads/report.pdf\".")
    ], required: ["url", "path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let url = URL(string: try args.requiredString("url")), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw ToolError.invalid("Please provide a valid http(s) URL.")
        }
        let (temp, response) = try await HTTP.session.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw ToolError.invalid("Download failed with HTTP \(status).") }
        var path = try args.requiredString("path")
        if (path as NSString).pathExtension.isEmpty,
           let mime = response.mimeType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            path += ".\(ext)"
        }
        let destination = try context.workspace.destination(for: path, overwrite: false)
        try FileManager.default.moveItem(at: temp, to: destination)
        let rel = context.workspace.relativePath(of: destination)
        let size = ByteCountFormatter().string(fromByteCount: Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        return ToolOutput(text: "Downloaded \(rel) (\(size)).", files: [rel])
    }
}

struct ClipboardTool: AgentTool {
    let name = "clipboard"
    let activityLabel = "Using clipboard"
    let description = "Read the clipboard text or copy text to the clipboard."
    let parameters = Schema.object([
        "action": Schema.string("read or write.", options: ["read", "write"]),
        "text": Schema.string("Text to copy (for write).")
    ], required: ["action"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let action = args.optionalString("action") ?? "read"
        if action == "write" {
            let text = try args.requiredString("text")
            await MainActor.run {
                #if os(iOS)
                UIPasteboard.general.string = text
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
            }
            return ToolOutput(text: "Copied \(text.count) characters to the clipboard.")
        }
        let text: String? = await MainActor.run {
            #if os(iOS)
            return UIPasteboard.general.string
            #else
            return NSPasteboard.general.string(forType: .string)
            #endif
        }
        return ToolOutput(text: text.map { "Clipboard contains:\n\($0.prefix(20_000))" } ?? "The clipboard has no text.")
    }
}

struct DateTimeTool: AgentTool {
    let name = "get_date_time"
    let activityLabel = "Checking the time"
    let description = "Get the current date and time, optionally in other time zones (IANA names like Europe/London)."
    let parameters = Schema.object([
        "time_zones": Schema.array("Extra IANA time zones (optional).", items: Schema.string("Time zone"))
    ])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let now = Date()
        func format(_ zone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = zone
            formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm (zzz)"
            return formatter.string(from: now)
        }
        var lines = ["Local: \(format(.current)) [\(TimeZone.current.identifier)]"]
        for name in args.stringArray("time_zones") {
            if let zone = TimeZone(identifier: name) { lines.append("\(name): \(format(zone))") }
            else { lines.append("\(name): unknown time zone") }
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

struct CalculatorTool: AgentTool {
    let name = "calculate"
    let activityLabel = "Calculating"
    let description = "Evaluate a math expression exactly: + - * / ^ %, parentheses, sqrt, sin, cos, tan, log (base 10), ln, abs, round, floor, ceil, pi, e."
    let parameters = Schema.object(["expression": Schema.string("Expression, e.g. \"(12.5*4)^2 / sqrt(16)\".")], required: ["expression"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let expression = try args.requiredString("expression")
        var parser = MathParser(expression)
        let value = try parser.parse()
        let formatted = value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        return ToolOutput(text: "\(expression) = \(formatted)")
    }
}

/// Small recursive-descent math parser (no NSExpression, which can crash on bad input).
struct MathParser {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) { chars = Array(text.replacingOccurrences(of: " ", with: "").lowercased()) }

    mutating func parse() throws -> Double {
        let value = try expression()
        guard index == chars.count else { throw ToolError.invalid("Unexpected character at position \(index + 1).") }
        return value
    }

    private var current: Character? { index < chars.count ? chars[index] : nil }

    private mutating func expression() throws -> Double {
        var value = try term()
        while let c = current, c == "+" || c == "-" {
            index += 1
            let rhs = try term()
            value = c == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func term() throws -> Double {
        var value = try power()
        while let c = current, c == "*" || c == "/" || c == "%" || c == "×" || c == "÷" {
            index += 1
            let rhs = try power()
            switch c {
            case "*", "×": value *= rhs
            case "/", "÷":
                guard rhs != 0 else { throw ToolError.invalid("Division by zero.") }
                value /= rhs
            default: value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    private mutating func power() throws -> Double {
        let base = try unary()
        if current == "^" {
            index += 1
            let exponent = try power()
            return pow(base, exponent)
        }
        return base
    }

    private mutating func unary() throws -> Double {
        if current == "-" {
            index += 1
            let value = try unary()
            return -value
        }
        if current == "+" { index += 1; return try unary() }
        return try primary()
    }

    private mutating func primary() throws -> Double {
        guard let c = current else { throw ToolError.invalid("Unexpected end of expression.") }
        if c == "(" {
            index += 1
            let value = try expression()
            guard current == ")" else { throw ToolError.invalid("Missing closing parenthesis.") }
            index += 1
            return value
        }
        if c.isNumber || c == "." {
            var text = ""
            while let d = current, d.isNumber || d == "." || d == "e" && !text.isEmpty && text.last?.isNumber == true && nextIsExponent() {
                text.append(d); index += 1
                if d == "e", let sign = current, sign == "-" || sign == "+" { text.append(sign); index += 1 }
            }
            guard let value = Double(text) else { throw ToolError.invalid("Invalid number \(text).") }
            return value
        }
        if c.isLetter {
            var name = ""
            while let d = current, d.isLetter || d.isNumber { name.append(d); index += 1 }
            switch name {
            case "pi": return Double.pi
            case "e": return M_E
            default: break
            }
            guard current == "(" else { throw ToolError.invalid("Unknown name \(name).") }
            let argument = try primary()
            switch name {
            case "sqrt": return sqrt(argument)
            case "sin": return sin(argument)
            case "cos": return cos(argument)
            case "tan": return tan(argument)
            case "log": return log10(argument)
            case "ln": return log(argument)
            case "abs": return abs(argument)
            case "round": return argument.rounded()
            case "floor": return floor(argument)
            case "ceil": return ceil(argument)
            case "exp": return exp(argument)
            default: throw ToolError.invalid("Unknown function \(name).")
            }
        }
        throw ToolError.invalid("Unexpected character \"\(c)\".")
    }

    private func nextIsExponent() -> Bool {
        let next = index + 1
        guard next < chars.count else { return false }
        return chars[next].isNumber || chars[next] == "-" || chars[next] == "+"
    }
}
