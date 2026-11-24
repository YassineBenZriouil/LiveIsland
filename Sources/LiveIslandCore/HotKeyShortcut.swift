import Foundation

/// The keyboard shortcut that opens the island from anywhere. Kept as a key code and modifiers
/// (what Carbon's `RegisterEventHotKey` takes) plus the key's name as it was typed, since a key
/// code alone can't say what's printed on the key for the person's layout.
public struct HotKeyShortcut: Hashable, Sendable, Codable {
    /// The modifier keys, in our own bits: the app maps them to Carbon's.
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The virtual key code (kVK_…), the same on every layout.
    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// What's printed on the key, e.g. "I" or "Space".
    public var key: String

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌃⌥⌘Space: nothing in macOS or the usual apps uses it, and it's easy to reach.
    public static let standard = HotKeyShortcut(keyCode: 49, modifiers: [.control, .option, .command], key: "Space")

    /// A global shortcut needs ⌘, ⌃ or ⌥ (Shift alone would take a letter away from typing);
    /// function keys can stand alone.
    public var isUsable: Bool {
        if Self.functionKeys.keys.contains(keyCode) { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option]) && !key.isEmpty
    }

    /// How menus write it: ⌃⌥⇧⌘ in Apple's order, then the key.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// The saved form: compact JSON. A missing or unreadable value gives nil, and the
    /// caller falls back to `standard`.
    public init?(saved: String?) {
        guard let data = saved?.data(using: .utf8),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isUsable else { return nil }
        self = shortcut
    }

    public var saved: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The name of a key that doesn't type a character (Space, arrows, F-keys…), or nil for
    /// one that does: its name then comes from the layout.
    public static func keyName(forKeyCode code: UInt32) -> String? {
        functionKeys[code] ?? namedKeys[code]
    }

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let namedKeys: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 76: "⌤",
    ]
}

/// What one press of the island's shortcut does: open, then each press shows the next tab,
/// and the press after the last tab closes. One key does it all, so nothing else needs a
/// shortcut that could clash with another app's.
public enum ShortcutPress {
    public enum Step<Tab: Equatable>: Equatable {
        case open
        case show(Tab)
        case close
    }

    public static func step<Tab: Equatable>(isOpen: Bool, current: Tab, tabs: [Tab]) -> Step<Tab> {
        guard isOpen else { return .open }
        guard let index = tabs.firstIndex(of: current) else {
            return tabs.first.map { .show($0) } ?? .close
        }
        let next = tabs.index(after: index)
        return next < tabs.endIndex ? .show(tabs[next]) : .close
    }
}
