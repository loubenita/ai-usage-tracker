import Carbon.HIToolbox
import Foundation

/// Catches Esc while the panel is open without taking keyboard focus from the frontmost app.
/// A Carbon hot key needs no Accessibility permission, unlike a global key monitor.
/// It is registered only while the panel is open, so Esc works normally the rest of the time.
@MainActor
final class EscapeHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var isEnabled: Bool {
        get { hotKey != nil }
        set { newValue ? enable() : disable() }
    }

    private func enable() {
        guard hotKey == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return noErr }
                let hotKey = Unmanaged<EscapeHotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, context, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4149_5554), id: 1) // "AIUT"
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            NSLog("AIUsageTracker: could not register Esc hot key (%d)", status)
        }
    }

    private func disable() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
