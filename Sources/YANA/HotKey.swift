import AppKit
import Carbon.HIToolbox

/// The keyboard shortcut that shows or hides the note from any app: Control-Option-N. It's a Carbon hot key, the one
/// kind of system-wide shortcut macOS gives an app without a permission such as Accessibility or Input Monitoring.
@MainActor
final class HotKey {
    /// The keys, as menus write them
    static let title = "⌃⌥N"
    /// The N key, by where it is on the keyboard
    static let keyCode = UInt32(kVK_ANSI_N)
    static let modifiers = UInt32(controlKey | optionKey)

    /// What pressing the keys does
    var action: () -> Void = {}
    /// Whether macOS gave YANA the keys. It turns them down when macOS itself or another app already has them.
    private(set) var isRegistered = false
    /// What macOS calls this hot key when it's pressed
    let id: EventHotKeyID

    private let defaults: UserDefaults
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private static let key = "hotKey"
    /// "YANA"
    private static let signature: OSType = 0x59414E41
    private static var count: UInt32 = 0

    /// The tests take other keys, and keep their own settings
    init(defaults: UserDefaults = .standard, keyCode: UInt32 = HotKey.keyCode, modifiers: UInt32 = HotKey.modifiers) {
        self.defaults = defaults
        self.keyCode = keyCode
        self.modifiers = modifiers
        Self.count += 1
        id = EventHotKeyID(signature: Self.signature, id: Self.count)
    }

    /// Whether the shortcut is wanted: it is until it's turned off in the menu. Turning it on asks macOS for the keys
    /// again, so `isRegistered` says whether that worked.
    var isOn: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.key)
            apply()
        }
    }

    /// Takes the keys, if the shortcut is on. For when YANA starts.
    func start() {
        apply()
    }

    /// Gives the keys back, and stops listening for them
    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    /// A hot key was pressed. Gives back whether it was this one.
    @discardableResult
    func pressed(_ pressed: EventHotKeyID) -> Bool {
        guard pressed.signature == id.signature, pressed.id == id.id else { return false }
        action()
        return true
    }

    private func apply() {
        if isOn {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKey == nil else { return }
        listen()
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &hotKey)
        isRegistered = status == noErr && hotKey != nil
        if !isRegistered {
            hotKey = nil
            logger.error("macOS didn't give YANA its shortcut: error \(status)")
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isRegistered = false
    }

    private func listen() {
        guard handler == nil else { return }
        var press = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The dispatcher's target also hears the keys while a menu or an alert is open
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyPressed, 1, &press,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

/// What Carbon calls, on the main thread, when a hot key of this app's is pressed. `context` is the `HotKey` that
/// asked to hear of it. An event that isn't for that one is passed along.
private func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?,
                           _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let wasThisOne = MainActor.assumeIsolated {
        Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().pressed(id)
    }
    return wasThisOne ? noErr : OSStatus(eventNotHandledErr)
}
