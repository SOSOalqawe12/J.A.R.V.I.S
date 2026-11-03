import Foundation
import Contacts
#if os(iOS)
import UIKit
#endif

/// Runs the user's own Shortcuts – smart-home scenes, messages, settings,
/// any automation they've built.
struct RunShortcutTool: AgentTool {
    let name = "run_shortcut"
    let activityLabel = "Running shortcut"
    let description = """
    Run one of the user's Shortcuts by its exact name – e.g. smart-home scenes ("Good Night", "Lights On"), \
    sending messages, toggling settings, or any custom automation. Optionally pass text input.
    """
    let parameters = Schema.object([
        "name": Schema.string("Exact name of the shortcut."),
        "input": Schema.string("Optional text to pass to the shortcut.")
    ], required: ["name"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let shortcut = try args.requiredString("name")
        let input = args.optionalString("input")
        try await context.approve("Run the shortcut “\(shortcut)”?", detail: input.map { "Input: \($0)" } ?? "JARVIS wants to run one of your Shortcuts.")
        #if os(macOS)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputURL = folder.appendingPathComponent("output.txt")
        var arguments = ["run", shortcut, "--output-path", outputURL.path]
        if let input {
            let inputURL = folder.appendingPathComponent("input.txt")
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
            arguments += ["--input-path", inputURL.path]
        }
        let result = try await ProcessRunner.run("/usr/bin/shortcuts", arguments: arguments, timeout: 300)
        guard result.status == 0 else {
            return ToolOutput(text: "The shortcut failed (\(result.status)): \(result.stderr.prefix(1000))")
        }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? result.stdout
        return ToolOutput(text: output.isEmpty ? "Ran “\(shortcut)”." : "Ran “\(shortcut)”. Output:\n\(output.prefix(10_000))")
        #else
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        var items = [URLQueryItem(name: "name", value: shortcut)]
        if let input {
            items += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)]
        }
        items += [URLQueryItem(name: "x-success", value: "jarvis://"), URLQueryItem(name: "x-cancel", value: "jarvis://"), URLQueryItem(name: "x-error", value: "jarvis://")]
        components.queryItems = items
        guard let url = components.url else { throw ToolError.invalid("Invalid shortcut name.") }
        let opened = await UIApplication.shared.open(url)
        return ToolOutput(text: opened
            ? "Started “\(shortcut)”. The Shortcuts app opens briefly, then returns to JARVIS."
            : "Couldn't open the Shortcuts app.")
        #endif
    }
}

struct FindContactTool: AgentTool {
    let name = "find_contact"
    let activityLabel = "Looking up contacts"
    let description = "Look up people in the user's Contacts by name: phone numbers, emails, birthday, company, address."
    let parameters = Schema.object(["query": Schema.string("Name (or part of it).")], required: ["query"])

    func run(_ args: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try args.requiredString("query")
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { throw ToolError.invalid("Contacts access isn't allowed. Enable it in Settings › Privacy › Contacts › JARVIS.") }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactPostalAddressesKey
        ].map { $0 as CNKeyDescriptor }
        let contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
        guard !contacts.isEmpty else { return ToolOutput(text: "No contact matches \"\(query)\".") }
        let lines = contacts.prefix(10).map { contact -> String in
            var line = "• \([contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " "))"
            if !contact.organizationName.isEmpty { line += " (\(contact.organizationName))" }
            for phone in contact.phoneNumbers {
                let label = phone.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "phone"
                line += "\n   \(label): \(phone.value.stringValue)"
            }
            for email in contact.emailAddresses { line += "\n   email: \(email.value as String)" }
            if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
                line += "\n   birthday: \(day)/\(month)\(birthday.year.map { "/\($0)" } ?? "")"
            }
            if let address = contact.postalAddresses.first {
                line += "\n   address: " + CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
            }
            return line
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

/// Exports conversations as Markdown or PDF into the JARVIS folder.
enum ConversationExporter {
    static func markdown(_ conversation: Conversation) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        var lines = ["# \(conversation.title)", "_\(formatter.string(from: conversation.created))_", ""]
        for message in conversation.messages {
            switch message.role {
            case .user:
                let text = message.visibleText
                let files = message.attachments.map(\.name)
                guard !text.isEmpty || !files.isEmpty else { continue }
                lines.append("**You:** \(text)")
                if !files.isEmpty { lines.append("📎 " + files.joined(separator: ", ")) }
            case .assistant:
                let text = message.visibleText
                guard !text.isEmpty else { continue }
                lines.append(message.isLocalNotice ? "> \(text)" : "**JARVIS:** \(text)")
            case .tool:
                let files = message.toolResults.flatMap(\.files)
                if !files.isEmpty { lines.append("📁 Created: " + files.joined(separator: ", ")) }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func export(_ conversation: Conversation, asPDF: Bool) async throws -> URL {
        let safeTitle = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Chats/\(safeTitle.isEmpty ? "Conversation" : String(safeTitle.prefix(60)))"
        let text = markdown(conversation)
        if asPDF {
            let data = try await PDFMaker.render(html: PDFMaker.html(from: text, title: nil), title: conversation.title)
            let url = try Workspace.shared.destination(for: base + ".pdf", overwrite: false)
            try data.write(to: url)
            return url
        }
        let url = try Workspace.shared.destination(for: base + ".md", overwrite: false)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
