import AppKit
import LiveIslandCore
import SwiftUI

/// The island's movement, toned down under Reduce Motion (System Settings › Accessibility ›
/// Display): springs become a short ease with no bounce, blurred swaps a plain fade, and
/// pulsing symbols and press-scales stay still. Views read the setting from the environment,
/// so they follow it the moment it changes; button actions, which can't, ask the workspace.
enum Motion {
    /// What a spring turns into: quick enough that nothing seems to lag, with no overshoot.
    static let reducedAnimation = Animation.easeInOut(duration: 0.18)

    /// `animation`, or a short ease under Reduce Motion.
    static func animation(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? reducedAnimation : animation
    }

    /// For `withAnimation` in a button's action, outside any view's environment.
    static func animation(_ animation: Animation) -> Animation {
        self.animation(animation, reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// One view giving way to another: a blur-and-fade, or only the fade.
    static func swap(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : AnyTransition(.blurReplace).combined(with: .opacity)
    }
}

/// A symbol that pulses for attention (a call, a finished timer), and holds still under
/// Reduce Motion: its color already says enough.
struct PulsingSymbol: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(.pulse, isActive: !reduceMotion)
    }
}

extension View {
    func pulsing() -> some View { modifier(PulsingSymbol()) }
}

/// The closed island as VoiceOver reads it: one element saying what both wings show
/// together, which opens the island when activated. It reads the clock every 10 seconds,
/// so a timer or a working agent is told about with the right time, at almost no cost.
struct SpokenIsland: View {
    @EnvironmentObject private var model: IslandModel
    let activity: IslandActivity
    let request: AgentRequest?
    let meeting: MeetingLink?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(label(at: context.date))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the island")
                .accessibilityAction { model.expand() }
                .accessibilityActions {
                    if let meeting {
                        Button("Join on \(meeting.service.name)") { model.joinMeeting(meeting.url) }
                    }
                }
        }
    }

    private func label(at now: Date) -> String {
        // A paused timer doesn't count down: say what's actually left.
        if case .timer = activity, let remaining = model.timer?.remaining(at: now) {
            return IslandActivity.timer(endsAt: now.addingTimeInterval(remaining)).spokenLabel(now: now)
                + (model.timer?.isPaused == true ? ", paused" : "")
        }
        return activity.spokenLabel(now: now, request: request, hidingDetails: model.hidesDetails)
    }
}
