import AppKit
import LiveIslandCore
import SwiftUI

/// Sing With Me in Settings › Media: the switch with what it sends, a live preview of the
/// card, and every part of its look, its size and its timing.
struct SingWithMeSettings: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject var sing: SingWithMe

    var body: some View {
        Section {
            ToggleRow(symbol: "music.mic", tint: .purple, title: "Sing With Me",
                      detail: "The lyrics of the song playing, in time with it, in a small card under the notch", isOn: $sing.isEnabled)
            Text("Lyrics come from LRCLIB (lrclib.net), a free lyrics database. To find them, LiveIsland sends it the song's title, artist, album and length, and nothing else, only while a song plays and you're looking at the Media tab or the lyrics. Each song is asked for once and kept on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(sing.isOpen ? "Close Lyrics" : "Open Lyrics") { model.toggleLyrics() }
                Spacer()
                Text("Or liveisland://lyrics").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("Sing With Me")
        }
        if sing.isEnabled {
            let screen = LyricsScreen.current(for: model.islandDisplay)
            Section("Preview") {
                LyricsPreview(look: sing.appearance, size: screen.map { cardSize(on: $0) } ?? CGSize(width: 151, height: 68))
                    .frame(maxWidth: .infinity)
            }
            background
            text
            shape
            motion
            if let screen { size(on: screen) }
            timing
            Section {
                Button("Reset to Default Look") { withAnimation { sing.resetLook() } }
                    .disabled(sing.appearance == .standard)
            }
        }
    }

    private func cardSize(on screen: LyricsScreen) -> CGSize {
        screen.frame(for: sing.placement(for: screen.id), position: sing.appearance.position).size
    }

    // MARK: - Sections

    private var background: some View {
        Section("Background") {
            slider("Blur", value: $sing.appearance.blur, in: 0...1, label: percent(sing.appearance.blur, none: "None", full: "Full"))
            slider("Opacity", value: $sing.appearance.opacity, in: 0...1, label: percent(sing.appearance.opacity))
            Picker("Colour", selection: $sing.appearance.background) {
                ForEach(LyricsAppearance.Background.allCases) { Text($0.title).tag($0) }
            }
            if sing.appearance.background == .custom {
                ColorPicker("Custom colour", selection: Binding(get: { Color(sing.appearance.customColor) },
                                                                set: { sing.appearance.customColor = LyricsColor($0) }),
                            supportsOpacity: false)
            }
            Text("No blur and no opacity leave the words floating on your screen, with a soft shadow so they stay readable.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var text: some View {
        Section("Words") {
            slider("Size", value: $sing.appearance.textScale, in: LyricsTypography.scaleRange, step: 0.1,
                   label: "\(Int((sing.appearance.textScale * 100).rounded())) %")
            Picker("Weight", selection: $sing.appearance.weight) {
                ForEach(LyricsAppearance.Weight.allCases) { Text($0.title).tag($0) }
            }
            Picker("Highlight", selection: $sing.appearance.highlight) {
                ForEach(LyricsAppearance.Highlight.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Line being sung") {
                HStack {
                    Toggle("Automatic", isOn: Binding(get: { sing.appearance.currentColor == nil },
                                                      set: { sing.appearance.currentColor = $0 ? nil : sing.appearance.resolvedCurrentColor }))
                    if sing.appearance.currentColor != nil {
                        ColorPicker("Colour", selection: Binding(get: { Color(sing.appearance.resolvedCurrentColor) },
                                                                 set: { sing.appearance.currentColor = LyricsColor($0) }),
                                    supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            slider("Other lines", value: Binding(get: { 1 - sing.appearance.dimming }, set: { sing.appearance.dimming = 1 - $0 }),
                   in: 0...1, label: "\(Int((sing.appearance.otherLinesOpacity * 100).rounded())) % bright")
            Picker("Align", selection: $sing.appearance.alignment) {
                ForEach(LyricsAlignment.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Lines shown", selection: $sing.appearance.lines) {
                ForEach(LyricsLineCount.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("A small card shows fewer lines when more wouldn't be readable.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var shape: some View {
        Section("Shape") {
            slider("Corners", value: $sing.appearance.cornerRadius, in: LyricsAppearance.cornerRange, step: 1,
                   label: "\(Int(sing.appearance.cornerRadius)) pt")
            slider("Soft edges", value: $sing.appearance.edgeFade, in: 0...1,
                   label: percent(sing.appearance.edgeFade, none: "None", full: "Strong"))
            Toggle("Shadow", isOn: $sing.appearance.shadow)
            Text("Soft edges fade the card out the same way on all four sides.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var motion: some View {
        Section("Motion") {
            Picker("New line", selection: $sing.appearance.lineAnimation) {
                ForEach(LyricsAppearance.LineAnimation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("With Reduce Motion on (System Settings › Accessibility › Display), lines only fade.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var timing: some View {
        Section("Timing") {
            slider("Words", value: Binding(get: { sing.offset }, set: { sing.offset = LyricsOffset.stepped($0, by: 0) }),
                   in: LyricsOffset.range, step: LyricsOffset.step, label: LyricsOffset.label(sing.offset))
            Text("If the words run ahead of the song or behind it, move them by a tenth of a second at a time.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// The card's size and place on the island's display: a preset, or exact numbers (which
    /// make it custom). Dragging its edges does the same.
    private func size(on screen: LyricsScreen) -> some View {
        let placement = sing.placement(for: screen.id)
        let frame = screen.frame(for: placement, position: sing.appearance.position)
        let bounds = screen.bounds
        func apply(width: CGFloat, height: CGFloat) {
            let next = LyricsGeometry.sized(frame, width: width, height: height, within: bounds)
            sing.setPlacement(LyricsPlacement(preset: .custom, frame: screen.relative(next)), for: screen.id)
        }
        func field(_ title: String, value: CGFloat, least: CGFloat, whole: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0.rounded())) }),
                           in: Double(least)...Double(max(whole, least + 1)))
                        .frame(width: 160)
                    TextField(title, value: Binding(
                        get: { sing.sizeInPercent ? Double((value / whole * 100).rounded()) : Double(value.rounded()) },
                        set: { set(sing.sizeInPercent ? CGFloat($0) / 100 * whole : CGFloat($0)) }), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text(sing.sizeInPercent ? "%" : "pt").foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                }
            }
        }
        return Section {
            Picker("Size", selection: Binding(get: { placement.preset }, set: { preset in
                if preset == .custom {
                    sing.setPlacement(LyricsPlacement(preset: .custom, frame: screen.relative(frame)), for: screen.id)
                } else {
                    sing.setPlacement(LyricsPlacement(preset: preset), for: screen.id)
                }
            })) {
                ForEach(LyricsPreset.allCases) { Text($0.title).tag($0) }
            }
            field("Width", value: frame.width, least: LyricsGeometry.minimumSize.width, whole: bounds.width) {
                apply(width: $0, height: frame.height)
            }
            field("Height", value: frame.height, least: LyricsGeometry.minimumSize.height, whole: bounds.height) {
                apply(width: frame.width, height: $0)
            }
            Picker("Units", selection: $sing.sizeInPercent) {
                Text("Points").tag(false)
                Text("% of the screen").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("Position", selection: $sing.appearance.position) {
                ForEach(LyricsPosition.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Drag any edge or corner of the card to resize it, and drag the card to move it. Sizes are kept for each display.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset Size") {
                    sing.resetSize(for: screen.id)
                    sing.appearance.position = .underNotch
                }
                .disabled(placement == .standard && sing.appearance.position == .underNotch)
            }
        } header: {
            Text("Size and place")
        }
    }

    // MARK: - Pieces

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0.05,
                        label: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 180)
                Text(label).monospacedDigit().frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ value: Double, none: String? = nil, full: String? = nil) -> String {
        if let none, value < 0.01 { return none }
        if let full, value > 0.99 { return full }
        return "\(Int((value * 100).rounded())) %"
    }
}

/// The card as it will look, over a colourful stand-in for the desktop so blur and opacity
/// show. Its size is the real one, scaled down if it wouldn't fit here.
private struct LyricsPreview: View {
    let look: LyricsAppearance
    let size: CGSize

    private static let sample = Lyrics(lrc: """
    [00:01.00] The night is young and so are we
    [00:05.00] Sing it with me, sing it loud
    [00:09.00] Every word under the lights
    [00:13.00] Till the morning finds us here
    [00:17.00] One more chorus, one more time
    """) ?? .instrumental

    var body: some View {
        let shown = Self.fit(size)
        let layout = LyricsTypography.layout(panel: shown, lines: look.lines, scale: look.textScale)
        let lines = Self.sample.lines
        let range = LyricsLineCount.window(count: layout.lines ?? 5, around: 1, total: lines.count)
        ZStack {
            LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.3), Color(red: 0.35, green: 0.3, blue: 0.85),
                                    Color(red: 0.1, green: 0.6, blue: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 18) {
                ForEach(0..<6) { index in
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(index.isMultiple(of: 2) ? 0.55 : 0.2))
                        .frame(width: 26, height: 90).rotationEffect(.degrees(18))
                }
            }
            ZStack {
                LyricsSurface(look: look, artwork: nil, materialBlur: true)
                VStack(alignment: look.alignment.horizontal, spacing: layout.fontSize * 0.32) {
                    ForEach(Array(range), id: \.self) { index in
                        LyricLineView(line: lines[index], index: index, current: 1,
                                      fill: LyricsFill(index: 1, progress: 0.55, remaining: nil), synced: true,
                                      fontSize: layout.fontSize, look: look, compact: true, single: range.count == 1,
                                      canSeek: false) {}
                            .frame(maxWidth: .infinity, alignment: look.alignment.frame)
                    }
                }
                .foregroundStyle(Color(look.resolvedCurrentColor))
                .padding(.vertical, max(LyricsTypography.padding(panel: shown),
                                        CGFloat(look.softEdge(for: Double(shown.width), Double(shown.height))) * 0.6))
                .padding(.horizontal, max(10, CGFloat(look.softEdge(for: Double(shown.width), Double(shown.height))) * 0.6 + 4))
            }
            .frame(width: shown.width, height: shown.height)
            .mask(SoftEdges(look: look, size: shown))
            .clipShape(RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(look.shadow && (look.opacity >= 0.1 || look.blur >= 0.1) ? 0.35 : 0), radius: 10, y: 4)
            .environment(\.colorScheme, look.hasLightBackground ? .light : .dark)
        }
        .frame(height: max(shown.height + 40, 120))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the lyrics card")
    }

    /// The real size, shrunk to fit the preview.
    static func fit(_ size: CGSize) -> CGSize {
        let scale = min(1, 420 / max(size.width, 1), 180 / max(size.height, 1))
        return CGSize(width: max(100, size.width * scale), height: max(44, size.height * scale))
    }
}
