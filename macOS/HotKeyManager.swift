import Foundation
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon's RegisterEventHotKey
/// (works without Accessibility permission).
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private var nextID: UInt32 = 1

    /// keyCode: kVK_* constant; modifiers: Carbon flags (cmdKey, optionKey, controlKey, shiftKey).
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A52_5653), id: id) // 'JRVS'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        DispatchQueue.main.async { self.handlers[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr { HotKeyManager.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
