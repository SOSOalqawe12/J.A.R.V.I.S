import Foundation

/// Counts requests and tokens per brain per day, so it's easy to see what is
/// hitting rate limits (stored on-device, last 14 days).
@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    struct Entry: Codable, Hashable {
        var requests = 0
        var tokens = 0
    }

    struct Day: Codable, Hashable {
        var date: String
        var entries: [String: Entry]
    }

    @Published private(set) var days: [Day] = []
    private let key = "jarvis.usage"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Day].self, from: data) {
            days = decoded
        }
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func record(_ provider: ProviderKind, tokens: Int?) {
        let today = UsageTracker.dayKey()
        if days.last?.date != today { days.append(Day(date: today, entries: [:])) }
        var day = days[days.count - 1]
        var entry = day.entries[provider.rawValue] ?? Entry()
        entry.requests += 1
        entry.tokens += tokens ?? 0
        day.entries[provider.rawValue] = entry
        days[days.count - 1] = day
        if days.count > 14 { days.removeFirst(days.count - 14) }
        if let data = try? JSONEncoder().encode(days) { UserDefaults.standard.set(data, forKey: key) }
    }

    var today: [(provider: ProviderKind, entry: Entry)] {
        guard let day = days.last, day.date == UsageTracker.dayKey() else { return [] }
        return day.entries.compactMap { key, value -> (provider: ProviderKind, entry: Entry)? in
            guard let provider = ProviderKind(rawValue: key) else { return nil }
            return (provider: provider, entry: value)
        }
        .sorted { $0.entry.requests > $1.entry.requests }
    }

    func total(lastDays count: Int) -> Entry {
        days.suffix(count).flatMap { $0.entries.values }.reduce(into: Entry()) { result, entry in
            result.requests += entry.requests
            result.tokens += entry.tokens
        }
    }

    func reset() {
        days = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
