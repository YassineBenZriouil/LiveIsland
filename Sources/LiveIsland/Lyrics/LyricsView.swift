import AppKit
import LiveIslandCore
import QuartzCore
import SwiftUI

/// What the lyrics card asks its window to do.
struct LyricsActions {
    var close: () -> Void
    var choose: (LyricsPreset) -> Void
    var beginMove: () -> Void
    var move: () -> Void
    var endMove: () -> Void
}

extension Color {
    init(_ color: LyricsColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension LyricsColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent),
                  alpha: Double(ns.alphaComponent))
    }
}

extension LyricsAppearance.Weight {
    var font: Font.Weight {
        switch self {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

extension LyricsAlignment {
    var horizontal: HorizontalAlignment { self == .left ? .leading : self == .right ? .trailing : .center }
    var frame: Alignment { self == .left ? .leading : self == .right ? .trailing : .center }
    var text: TextAlignment { self == .left ? .leading : self == .right ? .trailing : .center }
    var unit: UnitPoint { self == .left ? .leading : self == .right ? .trailing : .center }
}

/// Fades toward the left and right sides, as much as the look asks.
struct EdgeFade: View {
    let reach: Double

    var body: some View {
        if reach > 0 {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: reach),
                                   .init(color: .black, location: 1 - reach), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            Color.black
        }
    }
}

/// Sing With Me's card: the words of the song, the line being sung bright and filling in as
/// it's sung, the others dimmed, on whatever background the person chose. A small card shows
/// its buttons only while the pointer is on it; a big one has a header with the track.
struct LyricsView: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    /// Not observed: the view reads artwork from it, and redraws when `sing` or `window` change.
    let model: IslandModel
    let actions: LyricsActions

    var body: some View {
        let size = window.frame.size
        let look = sing.appearance
        let big = LyricsTypography.showsHeader(panel: size)
        let header = window.header
        let shape = RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
        ZStack(alignment: .top) {
            LyricsSurface(look: look, artwork: model.artwork(for: sing.track), materialBlur: false)
            VStack(spacing: 0) {
                if big {
                    LyricsHeader(sing: sing, window: window, model: model, actions: actions, layout: header)
                        .frame(height: header.height)
                        .padding(.top, header.topInset)
                }
                LyricsBody(sing: sing, look: look,
                           size: CGSize(width: size.width, height: big ? size.height - header.height - header.topInset : size.height),
                           onSeek: { sing.seek(toLine: $0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomTrailing) {
                if big, sing.lyrics != nil {
                    Text("Lyrics provided by LRCLIB")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(look.resolvedCurrentColor).opacity(0.4))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .mask(EdgeFade(reach: look.fadeReach))
        .clipShape(shape)
        .contentShape(shape)
        .overlay(alignment: window.controlsAtTop ? .topTrailing : .bottomTrailing) {
            if !big {
                HoverControls(sing: sing, window: window, model: model, actions: actions)
                    .padding(LyricsControls.inset)
                    .opacity(window.isHovering ? 1 : 0)
                    .allowsHitTesting(window.isHovering)
                    .animation(.easeOut(duration: 0.15), value: window.isHovering)
            }
        }
        // Dragging anywhere moves the card; a tap on a line still seeks.
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in actions.move() }
            .onEnded { _ in actions.endMove() })
        .environment(\.colorScheme, look.hasLightBackground ? .light : .dark)
        .redacted(reason: window.hidesDetails ? .privacy : [])
    }
}

/// The card's background: the chosen colour at the chosen opacity (the cover's, deepened, by
/// default) and an optional outline. The blur of what's behind the window is the window's
/// own; the Settings preview stands in for it with a material.
struct LyricsSurface: View {
    let look: LyricsAppearance
    let artwork: ArtworkLook?
    /// Draws the blur in SwiftUI (Settings' preview) instead of the window's backdrop.
    let materialBlur: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
        ZStack {
            if materialBlur, look.blur > 0.02 {
                shape.fill(look.blur > 0.7 ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial)).opacity(look.blur)
            }
            shape.fill(color.opacity(look.opacity))
            if look.background == .artwork, look.opacity > 0.05, let image = artwork?.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .opacity(0.35 * look.opacity)
                    .clipShape(shape)
            }
            if look.border {
                shape.strokeBorder(look.hasLightBackground ? Color.black.opacity(0.18) : Color.white.opacity(0.22), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private var color: Color {
        switch look.background {
        case .artwork:
            return Color(nsColor: ArtworkPalette.deep(artwork.map { NSColor($0.accent) } ?? ArtworkPalette.fallback))
        case .dark: return Color(white: 0.08)
        case .light: return Color(white: 0.96)
        case .custom: return Color(look.customColor)
        }
    }
}

/// The × and the menu, for a small card: they fade in while the pointer is on it.
private struct HoverControls: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    let model: IslandModel
    let actions: LyricsActions

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                LyricsMenuItems(sing: sing, window: window, model: model, actions: actions)
            } label: {
                circle("slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Size, look and timing")
            .accessibilityLabel("Size, look and timing")
            Button(action: actions.close) { circle("xmark") }
                .buttonStyle(PressableStyle())
                .help("Close (Esc)")
                .accessibilityLabel("Close Sing With Me")
        }
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.black.opacity(0.55)))
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .contentShape(Circle())
    }
}

/// The menu behind the card's slider button: the most used settings, a tap away.
struct LyricsMenuItems: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    let model: IslandModel
    let actions: LyricsActions

    var body: some View {
        let preset = window.screen.map { sing.placement(for: $0.id).preset } ?? .small
        Section("Size") {
            ForEach(LyricsPreset.allCases.filter { $0 != .custom }) { option in
                Button { actions.choose(option) } label: {
                    Label(option.title, systemImage: preset == option ? "checkmark" : option.symbol)
                }
            }
            if sing.appearance.position == .free {
                Button("Back Under the Notch") { actions.choose(preset == .custom ? .small : preset) }
            }
        }
        Section("Look") {
            Picker("Blur", selection: $sing.appearance.blur) {
                Text("None").tag(0.0)
                Text("Some").tag(0.5)
                Text("Full").tag(1.0)
                if ![0, 0.5, 1].contains(sing.appearance.blur) { Text("Custom").tag(sing.appearance.blur) }
            }
            Picker("Background", selection: $sing.appearance.background) {
                ForEach(LyricsAppearance.Background.allCases) { Text($0.title).tag($0) }
            }
            Picker("Highlight", selection: $sing.appearance.highlight) {
                ForEach(LyricsAppearance.Highlight.allCases) { Text($0.title).tag($0) }
            }
        }
        Section("Words") {
            Button("Bigger") { sing.changeFontScale(by: 0.1) }
            Button("Smaller") { sing.changeFontScale(by: -0.1) }
            Picker("Lines", selection: $sing.appearance.lines) {
                ForEach(LyricsLineCount.allCases) { Text($0.title).tag($0) }
            }
        }
        Section("Timing: \(LyricsOffset.label(sing.offset))") {
            Button("Words Sooner by 0.1 s") { sing.nudgeOffset(by: 1) }
            Button("Words Later by 0.1 s") { sing.nudgeOffset(by: -1) }
            Button("Reset Timing") { sing.offset = 0 }.disabled(sing.offset == 0)
        }
        Divider()
        Button("Sing With Me Settings…") { model.openSettings(.media, anchor: "lyrics") }
    }
}

/// A big card's header: the track on the left and the buttons on the right, each beside the
/// camera (or below it when there isn't room).
private struct LyricsHeader: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    let model: IslandModel
    let actions: LyricsActions
    let layout: LyricsHeaderLayout

    var body: some View {
        let padding: CGFloat = 16
        HStack(spacing: 0) {
            trackInfo
                .frame(maxWidth: max(0, layout.leadingWidth - padding - 8), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: layout.gap.map { $0.upperBound - $0.lowerBound } ?? 12)
            HStack(spacing: 6) {
                Menu {
                    LyricsMenuItems(sing: sing, window: window, model: model, actions: actions)
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Size, look and timing")
                .accessibilityLabel("Size, look and timing")
                Button(action: actions.close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.primary.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Close (Esc)")
                .accessibilityLabel("Close Sing With Me")
            }
            .frame(maxWidth: max(0, layout.trailingWidth - padding), alignment: .trailing)
            .fixedSize()
        }
        .foregroundStyle(Color(sing.appearance.resolvedCurrentColor))
        .padding(.horizontal, padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var trackInfo: some View {
        if let track = sing.track {
            HStack(spacing: 9) {
                Artwork(image: model.artwork(for: track)?.image, size: 26, corner: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title).font(.system(size: 12, weight: .bold)).lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist).font(.system(size: 11, weight: .medium)).opacity(0.6).lineLimit(1)
                    }
                }
            }
            .privacySensitive()
            .allowsHitTesting(false)
        } else {
            Label("Sing With Me", systemImage: "music.mic").font(.system(size: 12, weight: .bold)).allowsHitTesting(false)
        }
    }
}

/// The lyrics themselves, or what stands in for them.
private struct LyricsBody: View {
    @ObservedObject var sing: SingWithMe
    let look: LyricsAppearance
    let size: CGSize
    let onSeek: (Int) -> Void

    var body: some View {
        let layout = LyricsTypography.layout(panel: size, lines: look.lines, scale: look.textScale)
        let color = Color(look.resolvedCurrentColor)
        Group {
            if !sing.isEnabled {
                SingWithMeOptIn(sing: sing)
            } else if sing.track == nil {
                message("Play a song to sing along", layout.fontSize)
            } else {
                switch sing.state {
                case .idle:
                    message(sing.track?.isPlaying == true ? "Looking for lyrics…" : "Lyrics load when the song plays", layout.fontSize)
                case .loading:
                    message("Looking for lyrics…", layout.fontSize)
                case .missing:
                    message("No lyrics for this song", layout.fontSize)
                case .failed:
                    VStack(spacing: 6) {
                        message("Couldn't reach LRCLIB", layout.fontSize)
                        if size.height > 80 { Button("Try Again") { sing.retry() }.glassButton() }
                    }
                case .found(let lyrics):
                    if lyrics.kind == .instrumental {
                        Text("Instrumental ♪").font(.system(size: layout.fontSize, weight: look.weight.font))
                    } else if lyrics.kind == .synced, let count = layout.lines {
                        FocusLines(sing: sing, lyrics: lyrics, look: look, count: count, fontSize: layout.fontSize, onSeek: onSeek)
                    } else {
                        ScrollingLines(sing: sing, lyrics: lyrics, look: look, size: size, fontSize: layout.fontSize, onSeek: onSeek)
                    }
                }
            }
        }
        .foregroundStyle(color)
        .padding(.vertical, LyricsTypography.padding(panel: size))
        .padding(.horizontal, max(10, size.width * look.fadeReach * 0.5))
    }

    private func message(_ text: String, _ fontSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: min(max(fontSize * 0.8, 10), 15), weight: .semibold))
            .opacity(0.75)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(look.needsTextShadow ? 0.35 : 0), radius: 3, y: 1)
    }
}

/// A few lines around the one being sung, for a card that shows a set number: each new line
/// slides up (or fades), the rest move with it.
private struct FocusLines: View {
    @ObservedObject var sing: SingWithMe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: Lyrics
    let look: LyricsAppearance
    let count: Int
    let fontSize: CGFloat
    let onSeek: (Int) -> Void

    var body: some View {
        let range = LyricsLineCount.window(count: count, around: sing.currentIndex, total: lyrics.lines.count)
        VStack(alignment: look.alignment.horizontal, spacing: fontSize * 0.32) {
            ForEach(Array(range), id: \.self) { index in
                LyricLineView(line: lyrics.lines[index], index: index, current: sing.currentIndex, fill: sing.fill, synced: true,
                              fontSize: fontSize, look: look, compact: true, single: count == 1,
                              canSeek: sing.canSeek) { onSeek(index) }
                    .frame(maxWidth: .infinity, alignment: look.alignment.frame)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(animation, value: sing.currentIndex)
    }

    private var animation: Animation? {
        if look.lineAnimation == .none { return nil }
        return Motion.animation(.spring(response: 0.42, dampingFraction: 0.88), reduced: reduceMotion)
    }

    private var transition: AnyTransition {
        if look.lineAnimation == .none { return .identity }
        if look.lineAnimation == .fade || reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                           removal: .move(edge: .top).combined(with: .opacity))
    }
}

/// Every line, scrolled so the one being sung sits at the anchor (or, for unsynced lyrics,
/// all of them to read through).
private struct ScrollingLines: View {
    @ObservedObject var sing: SingWithMe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: Lyrics
    let look: LyricsAppearance
    let size: CGSize
    let fontSize: CGFloat
    let onSeek: (Int) -> Void

    var body: some View {
        let synced = lyrics.kind == .synced
        let anchor = LyricsTypography.anchor(height: size.height)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: look.alignment.horizontal, spacing: fontSize * 0.5) {
                    Color.clear.frame(height: synced ? size.height * anchor : 0)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        LyricLineView(line: line, index: index, current: sing.currentIndex, fill: sing.fill, synced: synced,
                                      fontSize: fontSize, look: look, compact: false, single: false,
                                      canSeek: sing.canSeek) { onSeek(index) }
                            .frame(maxWidth: .infinity, alignment: look.alignment.frame)
                            .id(index)
                    }
                    Color.clear.frame(height: synced ? size.height * (1 - anchor) : fontSize)
                }
            }
            .scrollIndicators(.never)
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: sing.currentIndex) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: size) { _, _ in scroll(proxy, animated: false) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard lyrics.kind == .synced else { return }
        let anchor = UnitPoint(x: 0.5, y: LyricsTypography.anchor(height: size.height))
        let target = sing.currentIndex ?? 0
        if animated, look.lineAnimation != .none {
            withAnimation(Motion.animation(.spring(response: 0.5, dampingFraction: 0.88), reduced: reduceMotion)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }
}

/// One line: the one being sung in the current-line colour (filling in as it's sung, when
/// that's the highlight), the others dimmed.
struct LyricLineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let line: LyricLine
    let index: Int
    let current: Int?
    let fill: LyricsFill?
    let synced: Bool
    let fontSize: CGFloat
    let look: LyricsAppearance
    /// In a few-lines card: one line each, the current one may take two.
    let compact: Bool
    let single: Bool
    let canSeek: Bool
    let seek: () -> Void

    var body: some View {
        let isCurrent = synced && index == current && look.highlight != .off
        let fills = isCurrent && look.highlight == .fill && fill?.index == index && !line.isGap
        let bright = Color(look.resolvedCurrentColor)
        let opacity = look.highlight == .off || !synced ? 1 : (isCurrent && !fills ? 1 : look.otherLinesOpacity)
        styled(Text(line.isGap ? "♪" : line.text), isCurrent: isCurrent)
            .foregroundStyle(bright.opacity(opacity))
            .overlay {
                if fills, let fill {
                    LineFill(text: AnyView(styled(Text(line.text), isCurrent: true).foregroundStyle(bright)), fill: fill)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(look.needsTextShadow ? (isCurrent ? 0.4 : 0.25) : 0), radius: isCurrent ? 4 : 3, y: 1)
            .privacySensitive()
            .animation(Motion.animation(.easeOut(duration: 0.25), reduced: reduceMotion), value: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture { if canSeek { seek() } }
            .help(canSeek ? "Play from here" : "")
            .accessibilityAddTraits(canSeek ? .isButton : [])
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint(canSeek ? "Plays the song from this line" : "")
    }

    /// The same layout for the line and its fill, so the fill lies exactly over the words.
    private func styled(_ text: Text, isCurrent: Bool) -> some View {
        text
            .font(.system(size: line.isGap ? fontSize * 0.8 : fontSize, weight: look.weight.font))
            .multilineTextAlignment(look.alignment.text)
            .lineLimit(compact ? (isCurrent || single ? 2 : 1) : nil)
            .minimumScaleFactor(compact ? 0.75 : 1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The bright copy of the line being sung, shown through a mask that Core Animation sweeps
/// from left to right over the line's length: one animation per line, planned again on a
/// pause, a seek or a new rate, and still while paused.
private struct LineFill: NSViewRepresentable {
    let text: AnyView
    let fill: LyricsFill

    func makeNSView(context: Context) -> FillView { FillView(rootView: text) }

    func updateNSView(_ view: FillView, context: Context) {
        view.host.rootView = text
        view.apply(fill)
    }

    final class FillView: NSView {
        let host: NSHostingView<AnyView>
        private let gradient = CAGradientLayer()
        private var applied: LyricsFill?
        private static let soft = 0.08

        init(rootView: AnyView) {
            host = NSHostingView(rootView: rootView)
            super.init(frame: .zero)
            wantsLayer = true
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            gradient.locations = Self.locations(0)
            layer?.mask = gradient
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            host.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            if layer?.mask !== gradient { layer?.mask = gradient }
            CATransaction.commit()
        }

        /// The soft edge sits at `progress` of the way across.
        static func locations(_ progress: Double) -> [NSNumber] {
            let edge = progress * (1 + soft)
            return [0, max(0, edge - soft), min(1, max(edge, 0)), 1].map { NSNumber(value: $0) }
        }

        func apply(_ fill: LyricsFill) {
            guard fill != applied else { return }
            applied = fill
            gradient.removeAnimation(forKey: "fill")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.locations = Self.locations(fill.progress)
            CATransaction.commit()
            guard let remaining = fill.remaining, remaining > 0 else { return }
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = Self.locations(fill.progress)
            sweep.toValue = Self.locations(1)
            sweep.duration = remaining
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            sweep.fillMode = .forwards
            sweep.isRemovedOnCompletion = false
            gradient.add(sweep, forKey: "fill")
        }
    }
}

/// Before Sing With Me is on: what it does and what it sends, and the switch.
struct SingWithMeOptIn: View {
    @ObservedObject var sing: SingWithMe

    var body: some View {
        VStack(spacing: 9) {
            Text("Sing along with the lyrics").font(.system(size: 15, weight: .bold))
            Text("Lyrics come from LRCLIB, a free lyrics database. To find them, LiveIsland sends it the song's title, artist, album and length, and nothing else. Each song is asked for once and kept on this Mac.")
                .font(.system(size: 11))
                .opacity(0.75)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Not Now") { sing.close() }.glassButton()
                Button("Turn On") { sing.isEnabled = true }.glassButton(prominent: true)
            }
        }
    }
}
