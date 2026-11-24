import AppKit
import LiveIslandCore
import SwiftUI

/// What the lyrics view asks its window to do.
struct LyricsActions {
    var close: () -> Void
    var choose: (LyricsPreset) -> Void
    var beginMove: () -> Void
    var move: () -> Void
    var endMove: () -> Void
}

/// Sing With Me's window, like Spotify's lyrics: the artwork's color behind big bold words,
/// the line being sung bright, the ones sung dimmed, the ones coming dimmer, scrolling so the
/// current line sits a third of the way down.
struct LyricsView: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    /// Not observed: the view reads artwork from it, and redraws when `sing` or `window` change.
    let model: IslandModel
    let actions: LyricsActions

    var body: some View {
        let size = window.frame.size
        let header = window.header
        let corner: CGFloat = 26
        let top: CGFloat = window.hangsFromTop ? 0 : corner
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: corner,
                                           bottomTrailingRadius: corner, topTrailingRadius: top, style: .continuous)
        ZStack(alignment: .top) {
            LyricsBackground(look: model.artwork(for: sing.track), hangs: window.hangsFromTop)
            VStack(spacing: 0) {
                LyricsHeader(sing: sing, window: window, model: model, actions: actions, layout: header)
                    .frame(height: header.height)
                    .padding(.top, header.topInset)
                LyricsBody(sing: sing, size: CGSize(width: size.width, height: max(0, size.height - header.height - header.topInset)),
                           fontSize: LyricsTypography.fontSize(panel: size, scale: sing.fontScale))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomTrailing) {
                if sing.lyrics != nil {
                    Text("Lyrics provided by LRCLIB")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .redacted(reason: window.hidesDetails ? .privacy : [])
    }
}

/// The artwork's color, deepened so white words read on it, with the cover blurred into it,
/// darkening toward the top so it melts into the notch.
private struct LyricsBackground: View {
    let look: ArtworkLook?
    let hangs: Bool

    var body: some View {
        let base = ArtworkPalette.deep(look.map { NSColor($0.accent) } ?? ArtworkPalette.fallback)
        ZStack {
            Color(nsColor: base)
            if let image = look?.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 90)
                    .opacity(0.38)
                    .allowsHitTesting(false)
            }
            LinearGradient(colors: [.black.opacity(hangs ? 0.85 : 0.25), .black.opacity(0.05), .black.opacity(0.3)],
                           startPoint: .top, endPoint: .bottom)
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

/// The track on the left and the buttons on the right, each beside the camera (or below it
/// when there isn't room), on a strip that moves the window when dragged.
private struct LyricsHeader: View {
    @ObservedObject var sing: SingWithMe
    @ObservedObject var window: LyricsWindowState
    let model: IslandModel
    let actions: LyricsActions
    let layout: LyricsHeaderLayout

    var body: some View {
        let padding: CGFloat = 18
        HStack(spacing: 0) {
            trackInfo
                .frame(maxWidth: max(0, layout.leadingWidth - padding - 8), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: layout.gap.map { $0.upperBound - $0.lowerBound } ?? 12)
            buttons
                .frame(maxWidth: max(0, layout.trailingWidth - padding), alignment: .trailing)
                .fixedSize()
        }
        .padding(.horizontal, padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea(actions: actions))
    }

    @ViewBuilder private var trackInfo: some View {
        if let track = sing.track {
            HStack(spacing: 9) {
                Artwork(image: model.artwork(for: track)?.image, size: 26, corner: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title).font(.system(size: 12, weight: .bold)).lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
            }
            .privacySensitive()
            .allowsHitTesting(false)
        } else {
            Label("Sing With Me", systemImage: "music.mic").font(.system(size: 12, weight: .bold)).allowsHitTesting(false)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Size") {
                    ForEach(LyricsPreset.allCases) { preset in
                        if preset != .custom || window.preset == .custom {
                            Button { actions.choose(preset) } label: {
                                Label(preset.title, systemImage: window.preset == preset ? "checkmark" : preset.symbol)
                            }
                            .disabled(preset == .custom)
                        }
                    }
                }
                Section("Words") {
                    Button("Bigger") { sing.changeFontScale(by: 0.1) }
                    Button("Smaller") { sing.changeFontScale(by: -0.1) }
                    Picker("Align", selection: $sing.alignment) {
                        ForEach(LyricsAlignment.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Timing: \(LyricsOffset.label(sing.offset))") {
                    Button("Words Sooner by 0.1 s") { sing.nudgeOffset(by: 1) }
                    Button("Words Later by 0.1 s") { sing.nudgeOffset(by: -1) }
                    Button("Reset Timing") { sing.offset = 0 }.disabled(sing.offset == 0)
                }
                Divider()
                Button("Sing With Me Settings…") { model.openSettings(.media, anchor: "lyrics") }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Size, words and timing")
            .accessibilityLabel("Size, words and timing")
            Button(action: actions.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Close (Esc)")
            .accessibilityLabel("Close Sing With Me")
        }
    }
}

/// The lyrics themselves, or what stands in for them.
private struct LyricsBody: View {
    @ObservedObject var sing: SingWithMe
    let size: CGSize
    let fontSize: CGFloat

    var body: some View {
        if !sing.isEnabled {
            SingWithMeOptIn(sing: sing)
        } else if sing.track == nil {
            message("music.note", "Play a song to sing along")
        } else {
            switch sing.state {
            case .idle:
                message("play.fill", sing.track?.isPlaying == true ? "Looking for lyrics…" : "Lyrics load when the song plays")
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for lyrics…").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
            case .missing:
                message("quote.bubble", "No lyrics for this song")
            case .failed:
                VStack(spacing: 10) {
                    message("wifi.exclamationmark", "Couldn't reach LRCLIB")
                    Button("Try Again") { sing.retry() }.glassButton()
                }
            case .found(let lyrics):
                if lyrics.kind == .instrumental {
                    Text("Instrumental ♪").font(.system(size: fontSize, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                } else {
                    LyricsLines(sing: sing, lyrics: lyrics, size: size, fontSize: fontSize)
                }
            }
        }
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        }
        .multilineTextAlignment(.center)
    }
}

/// Every line, scrolled so the one being sung sits at the anchor. Each change of line is one
/// short animation; between lines nothing moves.
private struct LyricsLines: View {
    @ObservedObject var sing: SingWithMe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: Lyrics
    let size: CGSize
    let fontSize: CGFloat

    var body: some View {
        let synced = lyrics.kind == .synced
        let anchor = LyricsTypography.anchor(height: size.height)
        let alignment: HorizontalAlignment = sing.alignment == .center ? .center : .leading
        let frameAlignment: Alignment = sing.alignment == .center ? .center : .leading
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: alignment, spacing: fontSize * 0.55) {
                    // Room above and below, so the first and last lines can reach the anchor.
                    Color.clear.frame(height: synced ? size.height * anchor : fontSize * 0.4)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        LyricLineView(line: line, index: index, current: sing.currentIndex, synced: synced, fontSize: fontSize,
                                      alignment: sing.alignment, canSeek: sing.canSeek) { sing.seek(toLine: index) }
                            .frame(maxWidth: .infinity, alignment: frameAlignment)
                            .id(index)
                    }
                    Color.clear.frame(height: synced ? size.height * (1 - anchor) : fontSize * 2)
                }
                .padding(.horizontal, max(22, size.width * 0.045))
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: sing.currentIndex) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: size) { _, _ in scroll(proxy, animated: false) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard lyrics.kind == .synced else { return }
        let anchor = UnitPoint(x: 0.5, y: LyricsTypography.anchor(height: size.height))
        let target = sing.currentIndex ?? 0
        if animated {
            withAnimation(Motion.animation(.spring(response: 0.55, dampingFraction: 0.86), reduced: reduceMotion)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }
}

private struct LyricLineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let line: LyricLine
    let index: Int
    let current: Int?
    let synced: Bool
    let fontSize: CGFloat
    let alignment: LyricsAlignment
    let canSeek: Bool
    let seek: () -> Void

    var body: some View {
        let isCurrent = synced && index == current
        let isPast = synced && current.map { index < $0 } ?? false
        let opacity: Double = !synced ? 0.88 : isCurrent ? 1 : isPast ? 0.5 : 0.3
        Text(line.isGap ? "♪" : line.text)
            .font(.system(size: line.isGap ? fontSize * 0.8 : fontSize, weight: .bold))
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .lineSpacing(fontSize * 0.08)
            .foregroundStyle(.white.opacity(opacity))
            .shadow(color: .black.opacity(isCurrent ? 0.25 : 0), radius: 8, y: 2)
            .scaleEffect(isCurrent || reduceMotion || !synced ? 1 : 0.985, anchor: alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .privacySensitive()
            .animation(Motion.animation(.easeOut(duration: 0.35), reduced: reduceMotion), value: isCurrent)
            .animation(Motion.animation(.easeOut(duration: 0.35), reduced: reduceMotion), value: isPast)
            .contentShape(Rectangle())
            .onTapGesture { if canSeek { seek() } }
            .help(canSeek ? "Play from here" : "")
            .accessibilityAddTraits(canSeek ? .isButton : [])
            .accessibilityHint(canSeek ? "Plays the song from this line" : "")
    }
}

/// Before Sing With Me is on: what it does and what it sends, and the switch.
struct SingWithMeOptIn: View {
    @ObservedObject var sing: SingWithMe

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.mic").font(.system(size: 28, weight: .semibold))
            Text("Sing along with the lyrics").font(.system(size: 18, weight: .bold))
            Text("Lyrics come from LRCLIB, a free lyrics database. To find them, LiveIsland sends it the song's title, artist, album and length, and nothing else. Each song is asked for once and kept on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Not Now") { sing.close() }.glassButton()
                Button("Turn On Sing With Me") { sing.isEnabled = true }.glassButton(prominent: true)
            }
        }
        .padding(20)
    }
}

/// The header's empty space: dragging it moves the window.
private struct WindowDragArea: NSViewRepresentable {
    let actions: LyricsActions

    func makeNSView(context: Context) -> DragView { DragView(actions: actions) }
    func updateNSView(_ view: DragView, context: Context) { view.actions = actions }

    final class DragView: NSView {
        var actions: LyricsActions
        init(actions: LyricsActions) {
            self.actions = actions
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { actions.beginMove() }
        override func mouseDragged(with event: NSEvent) { actions.move() }
        override func mouseUp(with event: NSEvent) { actions.endMove() }
    }
}
