import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code, e.g. `UInt32(kVK_ANSI_L)`
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | optionKey)`
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1, &eventType, selfPointer, &handlerRef)
        guard installStatus == noErr else {
            Log.app.error("InstallEventHandler failed: \(installStatus)")
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x41_44_43_4B) /* 'ADCK' */, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            Log.app.error("RegisterEventHotKey failed: \(registerStatus)")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
