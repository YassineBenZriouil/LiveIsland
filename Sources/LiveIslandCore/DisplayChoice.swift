import Foundation

/// Which display the island lives on: the person's pick from Settings, or automatic.
public enum DisplayChoice: Hashable, Sendable {
    /// The display with a notch, else the one with the menu bar.
    case automatic
    /// A display by its UUID, which stays the same across restarts and reconnections.
    case display(String)

    /// The saved form: an empty string is automatic.
    public init(saved: String?) {
        if let saved, !saved.isEmpty { self = .display(saved) } else { self = .automatic }
    }

    public var saved: String {
        switch self {
        case .automatic: return ""
        case let .display(id): return id
        }
    }

    /// What a display looks like to the choice.
    public struct Display: Equatable, Sendable {
        public var id: String
        public var hasNotch: Bool
        /// The display with the menu bar (the first in System Settings' arrangement).
        public var isPrimary: Bool

        public init(id: String, hasNotch: Bool, isPrimary: Bool) {
            self.id = id
            self.hasNotch = hasNotch
            self.isPrimary = isPrimary
        }
    }

    /// The index of the display to use, or nil when there are none. A picked display that isn't
    /// connected falls back to automatic, and the pick is kept so the island returns when it is.
    public func pick(from displays: [Display]) -> Int? {
        if case let .display(id) = self, let index = displays.firstIndex(where: { $0.id == id }) {
            return index
        }
        return displays.firstIndex(where: \.hasNotch)
            ?? displays.firstIndex(where: \.isPrimary)
            ?? (displays.isEmpty ? nil : 0)
    }
}
