import AppKit
import Carbon.HIToolbox
import LiveIslandCore

/// One global shortcut through Carbon's `RegisterEventHotKey`. Unlike a global key monitor it
/// needs no Accessibility or Input Monitoring permission, sees only its own key, and costs
/// nothing until that key is pressed.
@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// "LIsl": tells our hot key apart from any other in the process.
    private static let signature: OSType = 0x4C49_736C

    /// Registers `shortcut` in place of the current one; nil just unregisters. False when macOS
    /// refused it, usually because another app already holds the same shortcut.
    @discardableResult
    func register(_ shortcut: HotKeyShortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, Self.carbonModifiers(shortcut.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hot keys on the main thread's run loop.
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress?() }
            return noErr
        }, 1, &type, context, &handler)
    }

    static func carbonModifiers(_ modifiers: HotKeyShortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// The shortcut a key press in Settings' recorder stands for.
    static func shortcut(from event: NSEvent) -> HotKeyShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: HotKeyShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let code = UInt32(event.keyCode)
        // The key as printed, without Shift or Option turning "1" into "!" or "¡".
        let key = HotKeyShortcut.keyName(forKeyCode: code)
            ?? event.characters(byApplyingModifiers: [])?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            ?? ""
        return HotKeyShortcut(keyCode: code, modifiers: modifiers, key: key)
    }
}

/// The island's shortcut setting: on or off, which keys, and the recorder in Settings › General.
@MainActor
final class IslandShortcut: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            apply()
        }
    }
    @Published private(set) var shortcut: HotKeyShortcut
    /// macOS refused the shortcut: another app has it.
    @Published private(set) var isTaken = false
    /// Settings is waiting for the next key press.
    @Published private(set) var isRecording = false

    var onPress: (() -> Void)? {
        get { hotKey.onPress }
        set { hotKey.onPress = newValue }
    }

    private let hotKey = HotKey()
    private let defaults = UserDefaults.standard
    private var recorder: Any?

    init() {
        defaults.register(defaults: [Key.enabled: true])
        isEnabled = defaults.bool(forKey: Key.enabled)
        shortcut = HotKeyShortcut(saved: defaults.string(forKey: Key.shortcut)) ?? .standard
    }

    func start() { apply() }

    func set(_ shortcut: HotKeyShortcut) {
        self.shortcut = shortcut
        defaults.set(shortcut.saved, forKey: Key.shortcut)
        apply()
    }

    func reset() {
        defaults.removeObject(forKey: Key.shortcut)
        shortcut = .standard
        apply()
    }

    /// Listens for the next key press in Settings (a local monitor, so only while LiveIsland's
    /// own window has the keyboard). The current shortcut is let go meanwhile, so typing it
    /// again is recorded rather than opening the island. Escape cancels.
    func startRecording() {
        guard !isRecording else { return }
        hotKey.unregister()
        isRecording = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        isRecording = false
        apply()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            stopRecording()
            return
        }
        let typed = HotKey.shortcut(from: event)
        guard typed.isUsable else { NSSound.beep(); return }
        shortcut = typed
        defaults.set(typed.saved, forKey: Key.shortcut)
        stopRecording()
    }

    private func apply() {
        guard !isRecording else { return }
        if isEnabled {
            isTaken = !hotKey.register(shortcut)
        } else {
            hotKey.register(nil)
            isTaken = false
        }
    }

    private enum Key {
        static let enabled = "shortcutEnabled"
        static let shortcut = "shortcut"
    }
}

extension IslandModel {
    /// The shortcut opens the island, then each press shows the next tab in Settings' order,
    /// and the press after the last tab closes it. It never activates LiveIsland, so the app
    /// in front keeps the keyboard.
    func shortcutPressed() {
        guard !isMovingIsland else { return }
        switch ShortcutPress.step(isOpen: isExpanded, current: tab, tabs: tabOrder) {
        case .open: expand()
        case .show(let next): tab = next
        case .close: collapse()
        }
    }
}
