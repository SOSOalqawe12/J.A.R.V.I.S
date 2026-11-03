import Foundation
import PDFKit

struct CreateFileTool: AgentTool {
    let name = "create_file"
    let activityLabel = "Creating file"
    let description = """
    Create a text-based file in the JARVIS folder (visible to the user). Use for notes (.txt/.md), lists, \
    code (.py/.swift/.js/...), web pages (.html), data (.csv/.json), calendar events (.ics), contacts (.vcf), etc. \
    Organise into folders such as Notes/, Documents/, Code/, Spreadsheets/.
    """
    let parameters = Schema.object([
        "path": Schema.string("Relative path including file name and extension, e.g. \"Notes/Shopping list.txt\"."),
        "content": Schema.string("Full text content of the file."),
        "overwrite": Schema.boolean("Replace an existing file with the same name (default false: a numbered copy is created).")
    ], required: ["path", "content"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try args.requiredString("path")
        let content = try args.requiredString("content")
        let url = try context.workspace.destination(for: path, overwrite: args.bool("overwrite"), defaultExtension: "txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Created \(rel) (\(content.count) characters).", files: [rel])
    }
}

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let activityLabel = "Reading file"
    let description = "Read a file from the JARVIS folder. Text files return their content, PDFs return their text, images are shown to you."
    let parameters = Schema.object([
        "path": Schema.string("Relative path of the file."),
        "max_characters": Schema.integer("Maximum characters of text to return (default 30000).")
    ], required: ["path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try context.workspace.resolve(try args.requiredString("path"))
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(args.optionalString("path") ?? "") }
        let limit = args.int("max_characters") ?? 30_000
        let rel = context.workspace.relativePath(of: url)
        let mime = Workspace.mimeType(for: url)

        if mime.hasPrefix("image/") {
            let data = try Data(contentsOf: url)
            guard let prepared = ImageCoder.preparedForModel(data) else { throw ToolError.invalid("Could not decode image \(rel).") }
            return ToolOutput(text: "Here is the image \(rel).", images: [Attachment(name: url.lastPathComponent, mimeType: prepared.mimeType, data: prepared.data)])
        }
        if mime == "application/pdf" {
            guard let document = PDFDocument(url: url) else { throw ToolError.invalid("Could not open PDF \(rel).") }
            let text = document.string ?? ""
            return ToolOutput(text: "PDF \(rel) – \(document.pageCount) pages:\n" + String(text.prefix(limit)))
        }
        let data = try Data(contentsOf: url)
        let looksBinary = data.prefix(8192).contains(0)
        guard !looksBinary, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ToolOutput(text: "\(rel) is a binary file (\(data.count) bytes, \(mime)).")
        }
        let truncated = text.count > limit ? String(text.prefix(limit)) + "\n…[truncated, \(text.count) characters total]" : text
        return ToolOutput(text: truncated)
    }
}

struct AppendFileTool: AgentTool {
    let name = "append_to_file"
    let activityLabel = "Updating file"
    let description = "Append text to the end of an existing text file (creates it if missing)."
    let parameters = Schema.object([
        "path": Schema.string("Relative path of the file."),
        "content": Schema.string("Text to append. Include a leading newline if needed.")
    ], required: ["path", "content"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try context.workspace.resolve(try args.requiredString("path"))
        let content = try args.requiredString("content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8))
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Appended \(content.count) characters to \(rel).", files: [rel])
    }
}

struct EditFileTool: AgentTool {
    let name = "edit_file"
    let activityLabel = "Editing file"
    let description = "Edit a text file by replacing exact text. Read the file first so the search text matches exactly."
    let parameters = Schema.object([
        "path": Schema.string("Relative path of the file."),
        "find": Schema.string("Exact text to find."),
        "replace": Schema.string("Replacement text."),
        "replace_all": Schema.boolean("Replace every occurrence (default: first only).")
    ], required: ["path", "find", "replace"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try context.workspace.resolve(try args.requiredString("path"))
        let find = try args.requiredString("find")
        let replacement = try args.requiredString("replace")
        var text = try String(contentsOf: url, encoding: .utf8)
        guard let first = text.range(of: find) else { throw ToolError.invalid("The text to find was not found in the file.") }
        let count: Int
        if args.bool("replace_all") {
            count = text.components(separatedBy: find).count - 1
            text = text.replacingOccurrences(of: find, with: replacement)
        } else {
            text.replaceSubrange(first, with: replacement)
            count = 1
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let rel = context.workspace.relativePath(of: url)
        return ToolOutput(text: "Replaced \(count) occurrence(s) in \(rel).", files: [rel])
    }
}

struct ListFilesTool: AgentTool {
    let name = "list_files"
    let activityLabel = "Looking at files"
    let description = "List files and folders in the JARVIS folder (or a sub-folder)."
    let parameters = Schema.object([
        "path": Schema.string("Relative folder path. Empty for the top level."),
        "recursive": Schema.boolean("Include sub-folders (default false).")
    ])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let folder = try context.workspace.resolve(args.optionalString("path") ?? "")
        var lines: [String] = []
        let formatter = ByteCountFormatter()
        func walk(_ url: URL, depth: Int) {
            for item in context.workspace.items(in: url) {
                guard lines.count < 400 else { return }
                let indent = String(repeating: "  ", count: depth)
                if item.isDirectory {
                    lines.append("\(indent)📁 \(item.name)/")
                    if args.bool("recursive") { walk(item.url, depth: depth + 1) }
                } else {
                    lines.append("\(indent)📄 \(item.name) (\(formatter.string(fromByteCount: item.size)))")
                }
            }
        }
        walk(folder, depth: 0)
        let rel = context.workspace.relativePath(of: folder)
        return ToolOutput(text: lines.isEmpty ? "\(rel) is empty." : "Contents of \(rel):\n" + lines.joined(separator: "\n"))
    }
}

struct CreateFolderTool: AgentTool {
    let name = "create_folder"
    let activityLabel = "Creating folder"
    let description = "Create a folder in the JARVIS folder."
    let parameters = Schema.object(["path": Schema.string("Relative folder path, e.g. \"Projects/Trip\".")], required: ["path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try context.workspace.resolve(try args.requiredString("path"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ToolOutput(text: "Folder ready: \(context.workspace.relativePath(of: url))")
    }
}

struct MoveFileTool: AgentTool {
    let name = "move_file"
    let activityLabel = "Moving file"
    let description = "Move or rename a file or folder inside the JARVIS folder."
    let parameters = Schema.object([
        "from": Schema.string("Current relative path."),
        "to": Schema.string("New relative path (including the new name).")
    ], required: ["from", "to"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let from = try context.workspace.resolve(try args.requiredString("from"))
        guard FileManager.default.fileExists(atPath: from.path) else { throw WorkspaceError.notFound(try args.requiredString("from")) }
        let to = try context.workspace.destination(for: try args.requiredString("to"), overwrite: false)
        try FileManager.default.moveItem(at: from, to: to)
        let rel = context.workspace.relativePath(of: to)
        return ToolOutput(text: "Moved to \(rel).", files: [rel])
    }
}

struct CopyFileTool: AgentTool {
    let name = "copy_file"
    let activityLabel = "Copying file"
    let description = "Duplicate a file or folder inside the JARVIS folder."
    let parameters = Schema.object([
        "from": Schema.string("Relative path to copy."),
        "to": Schema.string("Relative destination path.")
    ], required: ["from", "to"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let from = try context.workspace.resolve(try args.requiredString("from"))
        let to = try context.workspace.destination(for: try args.requiredString("to"), overwrite: false)
        try FileManager.default.copyItem(at: from, to: to)
        let rel = context.workspace.relativePath(of: to)
        return ToolOutput(text: "Copied to \(rel).", files: [rel])
    }
}

struct DeleteFileTool: AgentTool {
    let name = "delete_file"
    let activityLabel = "Deleting"
    let description = "Delete a file or folder from the JARVIS folder. The user is asked to confirm."
    let parameters = Schema.object(["path": Schema.string("Relative path to delete.")], required: ["path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try args.requiredString("path")
        let url = try context.workspace.resolve(raw)
        guard url.standardizedFileURL != context.workspace.root.standardizedFileURL else {
            throw ToolError.invalid("Refusing to delete the whole JARVIS folder.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(raw) }
        let rel = context.workspace.relativePath(of: url)
        try await context.approve("Delete \(url.lastPathComponent)?", detail: "JARVIS wants to delete \"\(rel)\". This can't be undone.")
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return ToolOutput(text: "Moved \(rel) to the Trash.")
        #else
        try FileManager.default.removeItem(at: url)
        return ToolOutput(text: "Deleted \(rel).")
        #endif
    }
}

struct ZipFolderTool: AgentTool {
    let name = "zip_folder"
    let activityLabel = "Zipping"
    let description = "Compress a folder (or file) in the JARVIS folder into a .zip archive."
    let parameters = Schema.object([
        "path": Schema.string("Relative path of the folder or file to compress."),
        "zip_path": Schema.string("Relative path for the .zip (optional).")
    ], required: ["path"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let source = try context.workspace.resolve(try args.requiredString("path"))
        guard FileManager.default.fileExists(atPath: source.path) else { throw WorkspaceError.notFound(try args.requiredString("path")) }
        let zipPath = args.optionalString("zip_path") ?? (context.workspace.relativePath(of: source) + ".zip")
        let destination = try context.workspace.destination(for: zipPath, overwrite: false, defaultExtension: "zip")

        // NSFileCoordinator's .forUploading option zips directories, so wrap a
        // single file in a temporary folder first.
        var target = source
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: temp.appendingPathComponent(source.lastPathComponent))
            target = temp
        }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: target, options: [.forUploading], error: &coordinationError) { zipURL in
            do { try FileManager.default.copyItem(at: zipURL, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        let rel = context.workspace.relativePath(of: destination)
        return ToolOutput(text: "Created archive \(rel).", files: [rel])
    }
}
