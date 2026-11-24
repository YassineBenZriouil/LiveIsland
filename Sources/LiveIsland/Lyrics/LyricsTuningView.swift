import LiveIslandCore
import SwiftUI

/// What the tuning panel asks the card to do.
struct LyricsTuningActions {
    var choose: (LyricsPreset) -> Void
    var settings: () -> Void
    var close: () -> Void
}

/// The card's own settings, attached to it: live sliders for what's tuned by eye, and chips
/// for the choices. Its sliders are drags, and its chips buttons, so they act on the first
/// click in a panel that never takes the keyboard.
struct LyricsTuningView: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    let actions: LyricsTuningActions

    var body: some View {
        let look = sing.appearance
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Sing With Me").font(.system(size: 13, weight: .bold))
                Spacer()
                CardIconButton(window: window, id: "tuning-close", symbol: "xmark", help: "Close", action: actions.close)
            }
            slider("Text size", fraction(look.textScale, LyricsTypography.scaleRange), "\(Int((look.textScale * 100).rounded())) %") {
                sing.appearance.textScale = value($0, LyricsTypography.scaleRange, step: 0.05)
            }
            slider("Blur", look.blur, percent(look.blur, none: "None", full: "Full")) { sing.appearance.blur = $0 }
            slider("Background", look.opacity, percent(look.opacity)) { sing.appearance.opacity = $0 }
            slider("Other lines", 1 - look.dimming, "\(Int((look.otherLinesOpacity * 100).rounded())) %") {
                sing.appearance.dimming = 1 - $0
            }
            slider("Soft edges", look.edgeFade, percent(look.edgeFade, none: "None", full: "Strong")) { sing.appearance.edgeFade = $0 }
            slider("Corners", fraction(look.cornerRadius, LyricsAppearance.cornerRange), "\(Int(look.cornerRadius)) pt") {
                sing.appearance.cornerRadius = value($0, LyricsAppearance.cornerRange, step: 1)
            }
            slider("Timing", fraction(sing.offset, LyricsOffset.range), LyricsOffset.label(sing.offset)) {
                sing.offset = LyricsOffset.stepped(value($0, LyricsOffset.range, step: LyricsOffset.step), by: 0)
            }
            chips("Lines", LyricsLineCount.allCases, selected: look.lines, title: \.title) { sing.appearance.lines = $0 }
            chips("Highlight", LyricsAppearance.Highlight.allCases, selected: look.highlight,
                  title: { $0 == .fill ? "Fill" : $0 == .line ? "Line" : "Off" }) { sing.appearance.highlight = $0 }
            chips("Colour", LyricsAppearance.Background.allCases, selected: look.background,
                  title: { $0 == .artwork ? "Cover" : $0.title }) { sing.appearance.background = $0 }
            let preset = window.screen.map { sing.placement(for: $0.id).preset } ?? .small
            chips("Size", LyricsPreset.allCases.filter { $0 != .custom }, selected: preset,
                  title: { $0 == .band ? "Wide" : $0 == .fullScreen ? "Full" : $0.title }) { actions.choose($0) }
            Button(action: actions.settings) {
                Text("More in Settings…").font(.system(size: 11, weight: .semibold)).opacity(0.7)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(14)
        .frame(width: LyricsTuning.size.width, height: LyricsTuning.size.height, alignment: .top)
        .foregroundStyle(.white)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func slider(_ title: String, _ fraction: Double, _ label: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(label).monospacedDigit().opacity(0.6)
            }
            .font(.system(size: 11, weight: .medium))
            CapsuleSlider(value: fraction, label: title, onChange: set)
        }
        .accessibilityElement(children: .contain)
    }

    private func chips<Option: Hashable>(_ title: String, _ options: [Option], selected: Option, title name: @escaping (Option) -> String,
                                         pick: @escaping (Option) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium))
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    Button { pick(option) } label: {
                        Text(name(option))
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .background(Capsule().fill(.white.opacity(option == selected ? 0.28 : 0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(option == selected ? .isSelected : [])
                }
            }
        }
    }

    private func fraction(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// A slider's 0…1 as a value in `range`, on its steps.
    private func value(_ fraction: Double, _ range: ClosedRange<Double>, step: Double) -> Double {
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    private func percent(_ value: Double, none: String? = nil, full: String? = nil) -> String {
        if let none, value < 0.01 { return none }
        if let full, value > 0.99 { return full }
        return "\(Int((value * 100).rounded())) %"
    }
}
