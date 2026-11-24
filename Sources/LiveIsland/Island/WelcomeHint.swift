import LiveIslandCore
import SwiftUI

/// The first launch's note in the open island: on a Mac with a notch the idle island is the
/// notch itself, so this is the one moment that shows LiveIsland is there and how to reach it.
struct WelcomeHint: View {
    @EnvironmentObject private var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("LiveIsland is running").font(.system(size: 14, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text(pointingHint)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Got It") { model.collapse() }
                        .glassButton(prominent: true)
                    if model.hasNoSwitcher {
                        Button("Set Up Account Switching") { model.openSettings(.accounts) }
                            .glassButton()
                            .help("claude-swap and ccswap switch Claude Code and Codex accounts, by hand or before one runs out")
                    }
                    Button("Settings") { model.openSettings(.island) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// Where to point, as the island sits on this display.
    private var pointingHint: String {
        let target = layout.isFloating ? "the island" : layout.hasNotch ? "the notch" : "the top middle of the screen"
        return "Point at \(target) to open it, or click it. It shows what's playing, your agents, calls and timers, and closes when the pointer leaves."
    }
}
