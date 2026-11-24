import Foundation
import Intents

/// Whether a Focus (Do Not Disturb, Work, Sleep, …) is on, as macOS shares it with apps the
/// person allowed. It's read only at the moment a sound would play, so nothing polls.
@MainActor
final class FocusStatus: ObservableObject {
    enum Access: Equatable {
        /// Not asked yet: sounds play as before.
        case notAsked
        case allowed
        /// Turned off in System Settings › Privacy & Security › Focus, or not available to this build.
        case denied
    }

    @Published private(set) var access: Access = FocusStatus.currentAccess()

    /// True in a Focus, false outside one, nil when macOS won't say.
    var isFocused: Bool? {
        guard access == .allowed else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    /// Asks macOS once, only after the person turned on something that needs it.
    func requestAccess() {
        access = Self.currentAccess()
        guard access == .notAsked else { return }
        INFocusStatusCenter.default.requestAuthorization { _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.access = Self.currentAccess() }
            }
        }
    }

    /// Settings shows the answer: the person may have changed it in System Settings.
    func refresh() {
        let now = Self.currentAccess()
        if now != access { access = now }
    }

    private static func currentAccess() -> Access {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}
