import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

enum ScreenCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case noDisplay
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "JARVIS needs Screen Recording permission: System Settings › Privacy & Security › Screen & System Audio Recording."
        case .noDisplay:
            return "No display found to capture."
        case .blocked(let app):
            return "Screen capture is paused while \(app) is in front (privacy list)."
        }
    }
}

@MainActor
enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    struct FrontmostInfo {
        let appName: String
        let bundleID: String
        let windowTitle: String?
    }

    static func frontmost() -> FrontmostInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var title: String?
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            title = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
            })?[kCGWindowName as String] as? String
        }
        return FrontmostInfo(appName: app.localizedName ?? "Unknown", bundleID: app.bundleIdentifier ?? "", windowTitle: title)
    }

    static func contextLine() -> String? {
        guard let info = frontmost() else { return nil }
        if let title = info.windowTitle, !title.isEmpty { return "frontmost app: \(info.appName) – \"\(title)\"" }
        return "frontmost app: \(info.appName)"
    }

    /// Captures the display under the mouse (JARVIS's own windows excluded).
    static func capture(maxPixel: CGFloat = 1568) async throws -> CGImage {
        if let front = frontmost() {
            let blocked = AppSettings.shared.blockedApps
            if blocked.contains(where: { front.appName.lowercased().contains($0) }) {
                throw ScreenCaptureError.blocked(front.appName)
            }
        }
        if !hasPermission {
            requestPermission()
            throw ScreenCaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, maxPixel / CGFloat(max(display.width, display.height)))
        config.width = max(1, Int(CGFloat(display.width) * scale))
        config.height = max(1, Int(CGFloat(display.height) * scale))
        config.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func captureAttachment() async throws -> Attachment {
        let image = try await capture()
        guard let attachment = ImageCoder.preparedForModel(image) else { throw ScreenCaptureError.noDisplay }
        return attachment
    }
}
