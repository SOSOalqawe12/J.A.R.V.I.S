import Foundation

/// Parses the date formats models typically produce.
enum DateParser {
    static func parse(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd h:mm a", "yyyy-MM-dd", "yyyy/MM/dd HH:mm", "yyyy/MM/dd", "dd/MM/yyyy HH:mm", "dd/MM/yyyy"
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func isDateOnly(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).range(of: "^\\d{4}[-/]\\d{2}[-/]\\d{2}$", options: .regularExpression) != nil
            || raw.trimmingCharacters(in: .whitespaces).range(of: "^\\d{2}/\\d{2}/\\d{4}$", options: .regularExpression) != nil
    }

    static func describe(_ date: Date, includeTime: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }
}
