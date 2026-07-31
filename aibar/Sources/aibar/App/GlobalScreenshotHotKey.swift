import AppKit
import Carbon.HIToolbox

/// Registers fn + 4 with macOS' native hot-key service. Unlike a global
/// NSEvent monitor, this does not require Accessibility/Input Monitoring
/// permission just to notice the shortcut while another app is active.
@MainActor
final class GlobalScreenshotHotKey {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    private static let identifier = EventHotKeyID(
        signature: OSType(0x53434458), // "SCDX"
        id: 1
    )

    init(action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
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
                guard status == noErr,
                      identifier.signature == OSType(0x53434458),
                      identifier.id == 1
                else { return OSStatus(eventNotHandledErr) }

                let owner = Unmanaged<GlobalScreenshotHotKey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                owner.action()
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )

        RegisterEventHotKey(
            UInt32(kVK_ANSI_4),
            UInt32(kEventKeyModifierFnMask),
            Self.identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
