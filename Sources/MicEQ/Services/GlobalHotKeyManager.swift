import Carbon
import Foundation

enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "macOS rejected this hotkey (OSStatus \(status)). Choose another key or combination."
        }
    }
}

final class GlobalHotKeyManager {
    private let signature = fourCharCode("MACQ")
    private let identifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (@Sendable () -> Void)?

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(_ hotKey: MACQHotKey?, callback: @Sendable @escaping () -> Void) throws {
        self.callback = callback
        unregister()

        guard let hotKey else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            throw GlobalHotKeyError.registrationFailed(status)
        }
        hotKeyRef = ref
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr,
                      pressedID.signature == manager.signature,
                      pressedID.id == manager.identifier else {
                    return noErr
                }
                let callback = manager.callback
                DispatchQueue.main.async {
                    callback?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.unicodeScalars.prefix(4).reduce(OSType(0)) { result, scalar in
        (result << 8) + OSType(scalar.value)
    }
}
