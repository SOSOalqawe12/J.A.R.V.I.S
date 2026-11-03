import Foundation
#if os(macOS)
import AppKit
#endif

/// Asks the user before JARVIS performs a sensitive action
/// (deleting files, running shell commands or AppleScript, ...).
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct Request: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published private(set) var pending: Request?
    private var queue: [Request] = []

    /// Set while running headless (Siri/Shortcuts) where nobody can answer.
    var headless = false

    func requestApproval(title: String, detail: String, sensitive: Bool = true) async -> Bool {
        #if os(macOS)
        if sensitive == false || AppSettings.shared.autoApproveActions { return true }
        #else
        if sensitive == false { return true }
        #endif
        if headless { return false }

        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail.count > 1500 ? String(detail.prefix(1500)) + "…" : detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return await withCheckedContinuation { continuation in
            let request = Request(title: title, detail: detail, continuation: continuation)
            if pending == nil { pending = request } else { queue.append(request) }
        }
        #endif
    }

    func resolve(_ approved: Bool) {
        guard let request = pending else { return }
        request.continuation.resume(returning: approved)
        pending = queue.isEmpty ? nil : queue.removeFirst()
    }
}
