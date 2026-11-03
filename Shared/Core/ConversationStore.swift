import Foundation

/// Persists conversations as JSON files in Application Support
/// (kept out of the user-visible JARVIS folder).
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var summaries: [ConversationSummary] = []

    private let folder: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("JARVIS/Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        loadIndex()
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private func fileURL(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? decoder.decode([ConversationSummary].self, from: data) {
            summaries = index.sorted { $0.updated > $1.updated }
        }
    }

    private func saveIndex() {
        if let data = try? encoder.encode(summaries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func load(_ id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    func save(_ conversation: Conversation) {
        // Don't litter history with empty chats.
        guard !conversation.messages.isEmpty else { return }
        if let data = try? encoder.encode(conversation) {
            try? data.write(to: fileURL(for: conversation.id), options: .atomic)
        }
        let summary = ConversationSummary(id: conversation.id, title: conversation.title, updated: conversation.updated, origin: conversation.origin)
        summaries.removeAll { $0.id == conversation.id }
        summaries.insert(summary, at: 0)
        saveIndex()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        summaries.removeAll { $0.id == id }
        saveIndex()
    }

    func deleteAll() {
        for summary in summaries { try? FileManager.default.removeItem(at: fileURL(for: summary.id)) }
        summaries = []
        saveIndex()
    }

    func rename(_ id: UUID, to title: String) {
        guard var conversation = load(id) else { return }
        conversation.title = title
        save(conversation)
    }
}
