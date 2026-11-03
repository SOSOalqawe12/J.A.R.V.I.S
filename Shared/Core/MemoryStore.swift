import Foundation

struct MemoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var created = Date()
}

/// Long-term facts JARVIS remembers about the user (stored on-device).
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var items: [MemoryItem] = []
    private let url: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JARVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent("memory.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([MemoryItem].self, from: data) {
            items = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }

    @discardableResult
    func add(_ text: String) -> MemoryItem? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = items.first(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        let item = MemoryItem(text: clean)
        items.append(item)
        if items.count > 200 { items.removeFirst(items.count - 200) }
        persist()
        return item
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Removes memories containing the query (case-insensitive). Returns what was removed.
    func remove(matching query: String) -> [MemoryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let removed = items.filter { $0.text.lowercased().contains(needle) }
        items.removeAll { $0.text.lowercased().contains(needle) }
        persist()
        return removed
    }

    func clear() {
        items.removeAll()
        persist()
    }

    var promptSection: String? {
        guard AppSettings.shared.memoryEnabled, !items.isEmpty else { return nil }
        return "# What you remember about the user\nUse these naturally when relevant; don't recite them.\n"
            + items.suffix(80).map { "- \($0.text)" }.joined(separator: "\n")
    }
}
