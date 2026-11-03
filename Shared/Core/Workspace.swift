import Foundation
import UniformTypeIdentifiers

enum WorkspaceError: LocalizedError {
    case outsideWorkspace(String)
    case notFound(String)
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path): return "The path \"\(path)\" is outside the JARVIS folder."
        case .notFound(let path): return "No file or folder at \"\(path)\"."
        case .alreadyExists(let path): return "\"\(path)\" already exists."
        }
    }
}

/// The folder JARVIS creates files in.
/// iOS: the app's Documents folder, which shows up in the Files app under
/// "On My iPhone › JARVIS". macOS: ~/Documents/JARVIS (configurable).
final class Workspace {
    static let shared = Workspace()

    private(set) var root: URL
    private let fm = FileManager.default

    private init() {
        root = Workspace.defaultRoot()
        ensureExists()
    }

    static func defaultRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        let custom = AppSettings.shared.workspacePath
        if !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return documents.appendingPathComponent("JARVIS", isDirectory: true)
        #else
        return documents
        #endif
    }

    func reloadRoot() {
        root = Workspace.defaultRoot()
        ensureExists()
    }

    func ensureExists() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        // Seed a friendly README the first time so the folder is not empty in Files.
        let readme = root.appendingPathComponent("Welcome to JARVIS.txt")
        if !fm.fileExists(atPath: readme.path),
           (try? fm.contentsOfDirectory(atPath: root.path).isEmpty) ?? true {
            try? "Everything JARVIS makes for you is saved in this folder.\nAsk: \"Make a packing list for Paris\" or \"Draw a neon city wallpaper\".\n"
                .write(to: readme, atomically: true, encoding: .utf8)
        }
        #endif
    }

    /// Internal folder for attachments, screenshots, etc. (hidden from listings).
    var internalFolder: URL {
        let url = root.appendingPathComponent(".jarvis", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolves a model-supplied path to a URL inside the workspace.
    func resolve(_ rawPath: String) throws -> URL {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = root.standardizedFileURL.path
        if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)) }
        if path.hasPrefix("~/") {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix(rootPath) { path = String(expanded.dropFirst(rootPath.count)) }
        }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty || path == "." { return root.standardizedFileURL }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw WorkspaceError.outsideWorkspace(rawPath)
        }
        return url
    }

    func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return url.lastPathComponent }
        var rel = String(full.dropFirst(rootPath.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? "." : rel
    }

    /// Returns a URL that does not collide with an existing file
    /// ("notes.txt" → "notes (2).txt").
    func uniqueURL(for url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// Prepares a destination for writing: creates parent folders and avoids
    /// overwriting unless asked to.
    func destination(for path: String, overwrite: Bool, defaultExtension: String? = nil) throws -> URL {
        var url = try resolve(path)
        if let defaultExtension, url.pathExtension.isEmpty {
            url = url.appendingPathExtension(defaultExtension)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return overwrite ? url : uniqueURL(for: url)
    }

    struct Item: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modified: Date

        var name: String { url.lastPathComponent }
        var type: UTType? { UTType(filenameExtension: url.pathExtension) }
        var isImage: Bool { type?.conforms(to: .image) ?? false }
    }

    func items(in folder: URL) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Item(
                url: url,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.modified > rhs.modified
        }
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func isTextFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return ["md", "csv", "tsv", "log", "ics", "vcf", "yaml", "yml", "toml", "ini", "env"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .commaSeparatedText) || type.conforms(to: .html)
    }
}
