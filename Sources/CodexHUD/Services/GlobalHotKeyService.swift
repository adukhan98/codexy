import Carbon.HIToolbox
import Foundation

private final class CarbonHotKeyRegistration: @unchecked Sendable {
    var eventHandler: EventHandlerRef?
    var hotKey: EventHotKeyRef?

    deinit {
        clear()
    }

    func clear() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKey = nil
        eventHandler = nil
    }
}

@MainActor
final class GlobalHotKeyService: GlobalHotKeyHandling {
    let shortcutDescription = "⇧⌥⌘Space"

    private static let signature: OSType = 0x4348_5544 // "CHUD"
    private static let identifier: UInt32 = 1

    private var action: (@MainActor () -> Void)?
    private let registration = CarbonHotKeyRegistration()

    func register(action: @escaping @MainActor () -> Void) throws {
        guard
            registration.hotKey == nil,
            registration.eventHandler == nil
        else {
            throw GlobalHotKeyFailure.shortcutUnavailable
        }

        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                guard
                    identifier.signature == 0x4348_5544,
                    identifier.id == 1
                else {
                    return OSStatus(eventNotHandledErr)
                }
                let service = Unmanaged<GlobalHotKeyService>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in
                    service.fire(identifier)
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &registration.eventHandler
        )
        guard handlerStatus == noErr else {
            self.action = nil
            throw GlobalHotKeyFailure.registrationFailed
        }

        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let modifierKeys = UInt32(cmdKey | optionKey | shiftKey)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifierKeys,
            identifier,
            GetApplicationEventTarget(),
            0,
            &registration.hotKey
        )
        guard registrationStatus == noErr else {
            registration.clear()
            self.action = nil
            throw GlobalHotKeyFailure.shortcutUnavailable
        }
    }

    func unregister() {
        registration.clear()
        action = nil
    }

    private func fire(_ identifier: EventHotKeyID) {
        guard
            identifier.signature == Self.signature,
            identifier.id == Self.identifier
        else {
            return
        }
        action?()
    }
}
