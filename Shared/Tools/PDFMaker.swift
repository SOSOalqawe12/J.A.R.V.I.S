import Foundation
import CoreText
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum PDFMaker {
    static let pageSize = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, points

    /// Turns HTML, Markdown or plain text into a styled HTML document.
    static func html(from content: String, title: String?) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeHTML = trimmed.range(of: "<(p|h[1-6]|div|ul|ol|table|br|html|body|section|b|strong|span)[ >/]", options: [.regularExpression, .caseInsensitive]) != nil
        var body = looksLikeHTML ? trimmed : markdownToHTML(trimmed)
        if let title, !body.lowercased().contains("<h1") {
            body = "<h1>\(escape(title))</h1>\n" + body
        }
        if body.lowercased().contains("<html") { return body }
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 12pt; color: #1a1a1a; line-height: 1.45; }
        h1 { font-size: 24pt; color: #0b3d63; margin-bottom: 6pt; }
        h2 { font-size: 17pt; color: #0b3d63; margin-top: 14pt; }
        h3 { font-size: 14pt; color: #12507f; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #b8c4ce; padding: 5px 7px; text-align: left; }
        th { background: #e8f1f8; }
        code, pre { font-family: Menlo, Courier, monospace; font-size: 10pt; }
        blockquote { color: #555; border-left: 3px solid #9ab; padding-left: 8px; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A small Markdown → HTML converter (headings, lists, bold/italic, code, rules, tables).
    static func markdownToHTML(_ markdown: String) -> String {
        var html: [String] = []
        var inList: String?
        var inCode = false
        var tableRows: [[String]] = []

        func inline(_ text: String) -> String {
            var s = escape(text)
            s = s.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
            s = s.replacingOccurrences(of: "(?<![*\\w])\\*(?!\\s)(.+?)\\*(?!\\w)", with: "<i>$1</i>", options: .regularExpression)
            s = s.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
            return s
        }
        func closeList() {
            if let list = inList { html.append("</\(list)>"); inList = nil }
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            var out = "<table>"
            for (index, row) in tableRows.enumerated() {
                let tag = index == 0 ? "th" : "td"
                out += "<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }
            html.append(out + "</table>")
            tableRows = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                closeList(); flushTable()
                html.append(inCode ? "</pre>" : "<pre>")
                inCode.toggle()
                continue
            }
            if inCode { html.append(escape(rawLine)); continue }

            if line.hasPrefix("|") && line.hasSuffix("|") {
                closeList()
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } && !$0.isEmpty }) { continue }
                tableRows.append(cells)
                continue
            } else {
                flushTable()
            }

            if line.isEmpty { closeList(); continue }
            if line == "---" || line == "***" { closeList(); html.append("<hr/>"); continue }
            if let level = ["###### ", "##### ", "#### ", "### ", "## ", "# "].first(where: { line.hasPrefix($0) }) {
                closeList()
                let depth = level.count - 1
                html.append("<h\(depth)>\(inline(String(line.dropFirst(level.count))))</h\(depth)>")
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if inList != "ul" { closeList(); html.append("<ul>"); inList = "ul" }
                html.append("<li>\(inline(String(line.dropFirst(2))))</li>")
                continue
            }
            if let match = line.range(of: "^\\d+[.)] ", options: .regularExpression) {
                if inList != "ol" { closeList(); html.append("<ol>"); inList = "ol" }
                html.append("<li>\(inline(String(line[match.upperBound...])))</li>")
                continue
            }
            if line.hasPrefix("> ") {
                closeList()
                html.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>")
                continue
            }
            closeList()
            html.append("<p>\(inline(line))</p>")
        }
        closeList()
        flushTable()
        if inCode { html.append("</pre>") }
        return html.joined(separator: "\n")
    }

    @MainActor
    static func render(html: String, title: String?) async throws -> Data {
        #if os(iOS)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let paper = pageSize
        let printable = paper.insetBy(dx: 50, dy: 54)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")
        let data = NSMutableData()
        var info: [String: Any] = [kCGPDFContextCreator as String: "JARVIS"]
        if let title { info[kCGPDFContextTitle as String] = title }
        UIGraphicsBeginPDFContextToData(data, paper, info)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for page in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            if page < renderer.numberOfPages { renderer.drawPage(at: page, in: bounds) }
        }
        UIGraphicsEndPDFContext()
        return data as Data
        #else
        guard let attributed = try? NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else {
            throw ToolError.invalid("Could not lay out the document.")
        }
        return try paginate(attributed, title: title)
        #endif
    }

    /// Lays out attributed text over as many pages as needed using Core Text.
    static func paginate(_ text: NSAttributedString, title: String?) throws -> Data {
        let data = NSMutableData()
        var mediaBox = pageSize
        var info: [CFString: Any] = [kCGPDFContextCreator: "JARVIS"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ToolError.invalid("Could not create a PDF context.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frameRect = pageSize.insetBy(dx: 54, dy: 60)
        var location = 0
        var pages = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            location += visible.length
            pages += 1
        } while location < text.length && pages < 500
        context.closePDF()
        return data as Data
    }
}
