import AppKit
import LiveIslandCore
import SwiftUI

private let tabSpring = Animation.spring(response: 0.36, dampingFraction: 0.82)

/// The open island: tabs and status beside the notch, the chosen page below it.
struct ExpandedIsland: View {
    @EnvironmentObject private var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabs
    let layout: IslandLayout

    var body: some View {
        // The camera housing hides whatever is under it: the tabs and the status each get the
        // room beside the notch, and the tabs drop their label when it wouldn't fit there.
        let width = layout.size(expanded: true, active: true).width
        let wing = max(0, (width - layout.headerGap) / 2 - 18 - 6)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    TabBar(namespace: tabs, labels: true)
                    TabBar(namespace: tabs, labels: false)
                }
                .frame(width: wing, alignment: .leading)
                Spacer(minLength: 0)
                StatusStrip().frame(width: wing, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: max(layout.notch.height, 32))

            ZStack(alignment: .top) {
                switch model.tab {
                case .media: MediaPage().transition(page)
                case .agents: AgentsPage().transition(page)
                case .activity: ActivityPage().transition(page)
                case .accounts: AccountsPage().transition(page)
                }
            }
            .overlay(alignment: .top) {
                if model.showsWelcome { WelcomeHint(layout: layout).transition(.opacity) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .background { AmbientGlow() }
        .animation(Motion.animation(tabSpring, reduced: reduceMotion), value: model.tab)
    }

    /// Pages blur into each other, or only fade under Reduce Motion.
    private var page: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }
}

// MARK: - Header

private struct TabBar: View {
    @EnvironmentObject private var model: IslandModel
    let namespace: Namespace.ID
    /// Show the selected tab's name (icons only when there's no room).
    var labels = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.visibleTabs) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(Motion.animation(tabSpring)) { model.tab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                        if selected && labels {
                            Text(tab.label).font(.system(size: 11, weight: .semibold, design: .rounded)).fixedSize()
                        }
                    }
                    .padding(.horizontal, selected ? 9 : 6.5)
                    .frame(height: 24)
                    .foregroundStyle(selected ? Color.white : .white.opacity(0.5))
                    .background {
                        if selected {
                            Capsule()
                                .fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .overlay(alignment: .topTrailing) { badge(for: tab) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.label)
                // Icons only when room is short: VoiceOver still says every tab's name.
                .accessibilityLabel(tab.label)
                .accessibilityValue(badgeDescription(for: tab) ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .liquidGlass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// The badge's dot in words.
    private func badgeDescription(for tab: IslandTab) -> String? {
        guard tab == .agents, model.tab != .agents else { return nil }
        if model.sessions.contains(where: { $0.state == .waiting }) { return "An agent needs you" }
        if model.sessions.contains(where: { $0.state == .working }) { return "An agent is working" }
        return nil
    }

    /// A dot on Agents when one needs attention or is at work.
    @ViewBuilder private func badge(for tab: IslandTab) -> some View {
        if tab == .agents, model.tab != .agents {
            if model.sessions.contains(where: { $0.state == .waiting }) {
                Circle().fill(.yellow).frame(width: 6, height: 6).offset(x: -2, y: 3)
            } else if model.sessions.contains(where: { $0.state == .working }) {
                Circle().fill(AgentGlyph(kind: .claude).color).frame(width: 6, height: 6).offset(x: -2, y: 3)
            }
        }
    }
}

/// Privacy dots, battery and the time, to the right of the notch.
private struct StatusStrip: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        // With five tabs beside a wide notch, room can run short: drop the percentage, never wrap.
        ViewThatFits(in: .horizontal) {
            strip(percent: true)
            strip(percent: false)
        }
    }

    private func strip(percent: Bool) -> some View {
        HStack(spacing: 9) {
            if model.system.cameraOn {
                Circle().fill(.green).frame(width: 6, height: 6).help("Camera in use").accessibilityLabel("Camera in use")
            }
            if !model.system.microphoneApps.isEmpty {
                Circle().fill(.orange).frame(width: 6, height: 6).help("Microphone in use").accessibilityLabel("Microphone in use")
            }
            if let battery = model.system.battery {
                HStack(spacing: 5) {
                    if percent { Text("\(battery.percent)%").monospacedDigit() }
                    BatteryGlyph(percent: battery.percent, charging: battery.isCharging || battery.onPower)
                }
                .help("\(battery.percent)%")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(battery.isCharging ? "Battery, charging" : battery.onPower ? "Battery, on power" : "Battery")
                .accessibilityValue("\(battery.percent)%")
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
            }
            Button { model.beginMovingIsland() } label: {
                Image(systemName: "pin.fill").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Move the island: it follows the pointer; press ⌘ to place it")
            .accessibilityLabel("Move the island")
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .lineLimit(1)
        .fixedSize()
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.75))
    }
}

struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    var width: CGFloat = 22

    var body: some View {
        let height = width / 2
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, (width - 4) * CGFloat(min(percent, 100)) / 100))
                    .padding(2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.75, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: height)
            Capsule().fill(.white.opacity(0.45)).frame(width: 1.5, height: height * 0.4)
        }
    }

    private var color: Color {
        charging ? .green : percent <= 20 ? .red : .white
    }
}

/// A soft wash of color behind each page: the artwork on Media, the agents' colors on Agents,
/// the tiles' colors on Activity.
private struct AmbientGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        if model.ambientGlow {
            ZStack {
                switch model.tab {
                case .media: ArtworkGlow()
                case .agents: AgentsGlow()
                case .activity: ActivityGlow()
                case .accounts: AccountsGlow()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }
}

/// Radial glows: no blur needed, so they cost next to nothing.
private struct Glows: View {
    let spots: [(color: Color, point: UnitPoint, radius: CGFloat)]

    var body: some View {
        ZStack {
            ForEach(spots.indices, id: \.self) { index in
                RadialGradient(colors: [spots[index].color, .clear], center: spots[index].point,
                               startRadius: 0, endRadius: spots[index].radius)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .transition(.opacity)
    }
}

private struct AgentsGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let claude = AgentGlyph(kind: .claude).color
        let codex = AgentGlyph(kind: .codex).color
        let waiting = model.sessions.contains { $0.state == .waiting }
        let working = model.sessions.contains { $0.state == .working }
        Glows(spots: [
            (claude.opacity(working ? 0.42 : 0.3), UnitPoint(x: 0.1, y: 0.75), 320),
            (codex.opacity(0.28), UnitPoint(x: 0.9, y: 0.85), 300),
            (waiting ? Color.yellow.opacity(0.22) : Color.purple.opacity(0.14), UnitPoint(x: 0.45, y: 0.15), 260),
        ])
        .animation(.easeInOut(duration: 0.8), value: waiting)
        .animation(.easeInOut(duration: 0.8), value: working)
    }
}

/// Green while the account in use has room, amber once it ran out.
private struct AccountsGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let exhausted = model.exhaustedAccount != nil || model.exhaustedCodexAccount != nil
        Glows(spots: [
            ((exhausted ? Color.orange : .green).opacity(0.26), UnitPoint(x: 0.1, y: 0.8), 320),
            (Color.indigo.opacity(0.26), UnitPoint(x: 0.9, y: 0.9), 300),
            (AgentGlyph(kind: .claude).color.opacity(0.2), UnitPoint(x: 0.5, y: 0.1), 260),
        ])
        .animation(.easeInOut(duration: 0.8), value: exhausted)
    }
}

private struct ActivityGlow: View {
    var body: some View {
        Glows(spots: [
            (Color.orange.opacity(0.28), UnitPoint(x: 0.08, y: 0.35), 260),
            (Color.red.opacity(0.2), UnitPoint(x: 0.5, y: 0.2), 240),
            (Color.green.opacity(0.24), UnitPoint(x: 0.95, y: 0.4), 260),
            (Color.blue.opacity(0.28), UnitPoint(x: 0.2, y: 1), 280),
            (Color.purple.opacity(0.2), UnitPoint(x: 0.8, y: 1), 260),
        ])
    }
}

/// The artwork, blurred into a glow behind the media page.
private struct ArtworkGlow: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        if let look = model.artwork(for: model.nowPlaying) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: look.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 340, height: 300)
                    .blur(radius: 70)
                    .opacity(0.6)
                    .offset(x: -70, y: 20)
                RadialGradient(colors: [look.accent.opacity(0.28), .clear], center: .bottomLeading, startRadius: 10, endRadius: 420)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .transition(.opacity)
        } else {
            // No cover (a video, a podcast without art, or nothing at all): a warm music glow.
            Glows(spots: [
                (Color.pink.opacity(0.3), UnitPoint(x: 0.1, y: 0.7), 300),
                (Color.purple.opacity(0.26), UnitPoint(x: 0.85, y: 0.9), 300),
            ])
        }
    }
}

// MARK: - Media

private struct MediaPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        if let track = model.nowPlaying {
            let accent = model.accent
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    CoverArt(track: track, accent: accent).privacySensitive()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                                Text(subtitle(track)).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            .privacySensitive()
                            Spacer(minLength: 0)
                            Waveform(meter: model.levels, style: .large, color: accent, playing: track.isPlaying)
                                .opacity(track.isPlaying ? 1 : 0.45)
                                .padding(.top, 2)
                        }
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ScrubBar(track: track, now: context.date, accent: accent)
                        }
                        Spacer(minLength: 6)
                        Controls(track: track, accent: accent)
                    }
                    .frame(height: 116)
                }
                HStack(spacing: 12) {
                    PlayerSwitcher()
                    Spacer(minLength: 0)
                    VolumeRow(accent: accent)
                }
                .frame(height: 26)
                QueueStrip(accent: accent)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            EmptyMedia()
        }
    }

    private func subtitle(_ track: NowPlaying) -> String {
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? AppInfo.name(track.bundleIdentifier) ?? " " : parts.joined(separator: " — ")
    }
}

private struct CoverArt: View {
    @EnvironmentObject private var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: NowPlaying
    let accent: Color

    var body: some View {
        Button { model.openPlayerApp() } label: {
            ZStack(alignment: .bottomTrailing) {
                Artwork(image: model.artwork(for: track)?.image, size: 116, corner: 22)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: accent.opacity(0.45), radius: 18, y: 6)
                    // Paused, the cover sinks back a little; under Reduce Motion it stays put.
                    .scaleEffect(track.isPlaying || reduceMotion ? 1 : 0.94)
                    .animation(Motion.animation(.spring(response: 0.45, dampingFraction: 0.7), reduced: reduceMotion), value: track.isPlaying)
                if let icon = AppInfo.icon(track.bundleIdentifier) {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                        .offset(x: 7, y: 7)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .help("Open \(AppInfo.name(track.bundleIdentifier) ?? "the app")")
        .accessibilityLabel("Open \(AppInfo.name(track.bundleIdentifier) ?? "the app")")
    }
}

private struct ScrubBar: View {
    @EnvironmentObject private var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: NowPlaying
    let now: Date
    let accent: Color

    var body: some View {
        let duration = track.duration ?? 0
        let fraction = model.scrubbing ?? track.progress(at: now) ?? 0
        let position = model.scrubbing.map { $0 * duration } ?? track.position(at: now) ?? 0
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.85), .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, proxy.size.width * CGFloat(fraction)))
                        .shadow(color: accent.opacity(0.6), radius: 4)
                }
                .frame(height: model.scrubbing == nil ? 5 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        model.scrubbing = min(max(0, Double(drag.location.x / proxy.size.width)), 1)
                    }
                    .onEnded { drag in
                        guard duration > 0 else { return }
                        model.seek(to: min(max(0, Double(drag.location.x / proxy.size.width)), 1) * duration)
                        model.scrubbing = nil
                    })
                .animation(Motion.animation(.spring(response: 0.25, dampingFraction: 0.8), reduced: reduceMotion), value: model.scrubbing == nil)
            }
            .frame(height: 10)
            HStack {
                Text(Format.clock(position))
                Spacer()
                Text(duration > 0 ? "-" + Format.clock(max(0, duration - position)) : "Live")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
        // One slider for VoiceOver: where the track is, moved 15 seconds per swipe like the
        // buttons beside it. A live stream has nowhere to go.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(duration > 0 ? "\(Spoken.duration(position)) of \(Spoken.duration(duration))" : "Live")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            switch direction {
            case .increment: model.skip(by: 15)
            case .decrement: model.skip(by: -15)
            @unknown default: break
            }
        }
    }
}

private struct Controls: View {
    @EnvironmentObject private var model: IslandModel
    let track: NowPlaying
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            control("gobackward.15", size: 15, label: "Back 15 seconds") { model.skip(by: -15) }.help("Back 15 seconds")
            Spacer(minLength: 0)
            control("backward.fill", size: 18, label: "Previous track") { model.previousTrack() }
            Spacer(minLength: 0)
            Button { model.togglePlayPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .liquidGlass(in: Circle(), tint: accent.opacity(0.35), interactive: true)
            .accessibilityLabel(track.isPlaying ? "Pause" : "Play")
            Spacer(minLength: 0)
            control("forward.fill", size: 18, label: "Next track") { model.nextTrack() }
            Spacer(minLength: 0)
            control("goforward.15", size: 15, label: "Forward 15 seconds") { model.skip(by: 15) }.help("Forward 15 seconds")
        }
        .padding(.horizontal, 6)
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Every player with something loaded (tap to switch), then installed players that are idle
/// (tap to open and play).
private struct PlayerSwitcher: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.players, id: \.bundleIdentifier) { player in
                let selected = player.bundleIdentifier == model.nowPlaying?.bundleIdentifier
                Button {
                    withAnimation(Motion.animation(.spring(response: 0.3, dampingFraction: 0.85))) { model.selectedPlayerID = player.bundleIdentifier }
                } label: {
                    chip(player.bundleIdentifier, named: selected, playing: player.isPlaying, selected: selected)
                }
                .buttonStyle(PressableStyle())
                .help(player.title)
                .accessibilityLabel(AppInfo.name(player.bundleIdentifier) ?? "Player")
                .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ForEach(model.idlePlayers, id: \.self) { bundle in
                Button { model.launchPlayer(bundle) } label: {
                    chip(bundle, named: false, playing: false, selected: false).opacity(0.55)
                }
                .buttonStyle(PressableStyle())
                .help("Play in \(AppInfo.name(bundle) ?? "the app")")
                .accessibilityLabel("Play in \(AppInfo.name(bundle) ?? "the app")")
            }
        }
    }

    private func chip(_ bundle: String?, named: Bool, playing: Bool, selected: Bool) -> some View {
        HStack(spacing: 5) {
            if let icon = AppInfo.icon(bundle) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            if named {
                Text(AppInfo.name(bundle) ?? "Player").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            if playing {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.2 : 0.06), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Up Next from Music's playlist, or the tracks played earlier: tap one to play it.
private struct QueueStrip: View {
    @EnvironmentObject private var model: IslandModel
    let accent: Color

    var body: some View {
        let current = model.nowPlaying
        let queue = current?.bundleIdentifier.flatMap { model.upNext[$0] } ?? []
        let history = model.history.filter { $0.trackID != current?.trackID }
        if !queue.isEmpty || !history.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(queue.isEmpty ? "RECENTLY PLAYED" : "UP NEXT")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.45))
                    // In capitals, VoiceOver could spell it out.
                    .accessibilityLabel(queue.isEmpty ? "Recently played" : "Up next")
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if let bundle = current?.bundleIdentifier, !queue.isEmpty {
                            ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
                                Button { model.play(item, in: bundle) } label: {
                                    TrackChip(title: item.title, artist: item.artist, image: nil, number: index + 1, accent: accent)
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel(item.artist.isEmpty ? "Play \(item.title)" : "Play \(item.title) by \(item.artist)")
                            }
                        } else {
                            ForEach(history) { track in
                                Button { model.play(track) } label: {
                                    TrackChip(title: track.title, artist: track.artist, image: track.image, number: nil, accent: accent,
                                              badge: AppInfo.icon(track.bundleIdentifier))
                                }
                                .buttonStyle(PressableStyle())
                                .help("Play \(track.title) in \(AppInfo.name(track.bundleIdentifier) ?? "its app")")
                                .accessibilityLabel("Play \(track.title) in \(AppInfo.name(track.bundleIdentifier) ?? "its app")")
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .transition(.opacity)
        }
    }
}

private struct TrackChip: View {
    let title: String
    let artist: String
    let image: NSImage?
    let number: Int?
    let accent: Color
    var badge: NSImage? = nil

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(number.map(String.init) ?? "♪").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let badge { Image(nsImage: badge).resizable().frame(width: 12, height: 12).offset(x: 3, y: 3) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).privacySensitive()
                Text(artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).privacySensitive()
            }
            .frame(maxWidth: 110, alignment: .leading)
        }
        .padding(4)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct VolumeRow: View {
    @EnvironmentObject private var model: IslandModel
    let accent: Color

    var body: some View {
        if let output = model.output {
            HStack(spacing: 8) {
                Button { model.volume.toggleMute() } label: {
                    Image(systemName: symbol(output)).font(.system(size: 12, weight: .semibold))
                        .frame(width: 18).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .help(output.muted ? "Unmute" : "Mute")
                .accessibilityLabel(output.muted ? "Unmute" : "Mute")
                if output.canSetVolume {
                    CapsuleSlider(value: output.muted ? 0 : Double(output.volume), tint: .white, label: "Volume") { model.volume.setVolume(Float($0)) }
                        .frame(width: 120)
                }
                OutputPicker(output: output)
                    .frame(maxWidth: 120, alignment: .leading)
            }
        }
    }

    private func symbol(_ output: OutputVolume.State) -> String {
        if output.muted || output.volume == 0 { return "speaker.slash.fill" }
        return output.volume < 0.34 ? "speaker.wave.1.fill" : output.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

}

/// The output's name, which opens a menu of the other outputs (AirPods, speakers, a display)
/// to send the sound to. With only one output, it's a plain label.
private struct OutputPicker: View {
    @EnvironmentObject private var model: IslandModel
    let output: OutputVolume.State

    var body: some View {
        if output.choices.count > 1 {
            Menu {
                ForEach(output.choices) { choice in
                    Button { model.volume.select(choice.id) } label: {
                        Label(choice.name, systemImage: choice.id == output.uid ? "checkmark" : Self.symbol(choice))
                    }
                }
            } label: {
                label(chevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose where the sound plays")
            .accessibilityLabel("Sound output")
            .accessibilityValue(output.device)
        } else {
            label(chevron: false)
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(output)).font(.system(size: 10, weight: .semibold))
            Text(output.device).lineLimit(1)
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
    }

    static func symbol(_ output: OutputVolume.State) -> String {
        if output.isBluetooth { return HeadphoneSymbol.name(for: output.device) }
        return output.isBuiltIn ? "laptopcomputer" : "hifispeaker.fill"
    }

    static func symbol(_ choice: AudioOutputChoice) -> String {
        switch choice.kind {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return HeadphoneSymbol.name(for: choice.name)
        case .display: return "display"
        case .airPlay: return "airplayaudio"
        case .wired, .virtual, .other: return "hifispeaker.fill"
        }
    }
}

/// A thin slider that thickens while dragged. VoiceOver reads it as a percentage and moves
/// it 5% per swipe.
struct CapsuleSlider: View {
    let value: Double
    var tint: Color = .white
    var label = "Volume"
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(tint).frame(width: max(5, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(min(max(0, Double(drag.location.x / proxy.size.width)), 1))
            })
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Spoken.percent(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(Spoken.stepped(value, up: true))
            case .decrement: onChange(Spoken.stepped(value, up: false))
            @unknown default: break
            }
        }
    }
}

private struct EmptyMedia: View {
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.25, blue: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 110, height: 110)
            .shadow(color: .pink.opacity(0.35), radius: 20, y: 6)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing playing").font(.system(size: 18, weight: .bold))
                Text("Music, podcasts and videos from any app show up here, with controls.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(["com.apple.Music", "com.spotify.client"], id: \.self) { bundle in
                        if let url = AppInfo.url(bundle) {
                            Button {
                                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                            } label: {
                                HStack(spacing: 6) {
                                    if let icon = AppInfo.icon(bundle) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                    Text("Open \(AppInfo.name(bundle) ?? "")").font(.system(size: 11, weight: .semibold))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(PressableStyle())
                            .liquidGlass(in: Capsule(), interactive: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Agents

private struct AgentsPage: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SessionsHeader()
                if model.sessions.isEmpty {
                    VStack(spacing: 8) {
                        HStack(spacing: -6) {
                            AgentAvatar(kind: .claude, state: .idle, size: 34)
                            AgentAvatar(kind: .codex, state: .idle, size: 34)
                        }
                        Text("No agents running").font(.system(size: 13, weight: .semibold))
                        Text("Claude Code and Codex sessions show up here as they work.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                        // Claude's limits in percent need the status line: the way there.
                        if model.showClaude, model.agents.claudeLimits == nil {
                            Button { model.openSettings(.agents) } label: {
                                Label("Show Claude's limits in %", systemImage: "gauge.with.dots.needle.50percent")
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(AgentGlyph(kind: .claude).color)
                            }
                            .buttonStyle(PressableStyle())
                            .help("Set up Claude Code's status line to pass its limits on, in Settings › AI Agents")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.sessions.prefix(8)) { session in
                                AgentRow(session: session)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            UsagePanel().frame(width: 214)
        }
    }
}

private struct SessionsHeader: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let working = model.sessions.filter { $0.state == .working }.count
        let waiting = model.sessions.filter { $0.state == .waiting }.count
        HStack(spacing: 6) {
            Text("Sessions").font(.system(size: 12, weight: .bold)).accessibilityAddTraits(.isHeader)
            if working > 0 { Chip(text: "\(working) working", color: AgentGlyph(kind: .claude).color) }
            if waiting > 0 { Chip(text: Spoken.plural(waiting, one: "1 needs you", other: "\(waiting) need you"), color: .yellow) }
            Spacer()
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// The agent's mark in a tinted square, ringed by a spinner while it works.
struct AgentAvatar: View {
    let kind: AgentKind
    let state: AgentState
    var size: CGFloat = 30

    var body: some View {
        let color = AgentGlyph(kind: kind).color
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            Image(systemName: kind == .claude ? "sparkle" : "terminal.fill")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state == .working {
                ProgressView().controlSize(.mini).tint(color)
                    .padding(1)
                    .background(Circle().fill(.black))
                    .offset(x: 4, y: 4)
            } else if state == .waiting {
                Circle().fill(.yellow).frame(width: 9, height: 9).overlay(Circle().stroke(.black, lineWidth: 2)).offset(x: 2, y: 2)
            } else if state == .done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    .background(Circle().fill(.black)).offset(x: 3, y: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.displayName)
        .accessibilityValue(Self.spokenState(state))
    }

    static func spokenState(_ state: AgentState) -> String {
        switch state {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject private var model: IslandModel
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(kind: session.kind, state: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1).privacySensitive()
                Text(session.title ?? session.kind.displayName).privacySensitive()
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                if let request = session.request { RequestLine(request: request) }
            }
            Spacer(minLength: 6)
            StateChip(session: session)
            HStack(spacing: 3) {
                if session.resumeCommand != nil {
                    rowButton(model.copiedSession == session.id ? "checkmark" : "doc.on.doc",
                              help: "Copy the command that resumes this session") { model.copyResumeCommand(session) }
                }
                if let host = session.host, let icon = AppInfo.icon(host.bundleIdentifier) {
                    Button { model.jump(to: session) } label: {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Go to this session in \(AppInfo.name(host.bundleIdentifier) ?? "its app")")
                    .accessibilityLabel("Go to this session in \(AppInfo.name(host.bundleIdentifier) ?? "its app")")
                } else {
                    rowButton("folder", help: "Open the project folder") { model.openSession(session) }
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(session.state == .idle ? 0.04 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.jump(to: session) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Go to session") { model.jump(to: session) }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white.opacity(0.7))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// What the agent waits on the person for: the command it wants to run, the file it wants to
/// change, or its question, so "Needs you" can be answered without going to look first. It's
/// cut to two lines (the summary is already one short line, `AgentRequest.maxLength`) and
/// blurs while the screen is shared: commands and questions can say a lot about the work.
private struct RequestLine: View {
    let request: AgentRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: request.symbol).font(.system(size: 9, weight: .semibold))
            Text(request.text).privacySensitive()
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.yellow.opacity(0.9))
        .padding(.top, 1)
    }
}

private struct StateChip: View {
    let session: AgentSession

    var body: some View {
        Group {
            switch session.state {
            case .working:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let since = context.date.timeIntervalSince(session.workingSince ?? session.lastActivity)
                    Chip(text: Format.span(since), color: AgentGlyph(kind: session.kind).color)
                        .accessibilityLabel("Working for \(Spoken.duration(since))")
                }
            case .waiting:
                Chip(text: "Needs you", color: .yellow)
            case .done where session.request?.kind == .question:
                // The turn ended on a question: it's the person's move, not finished work.
                Chip(text: "Asks you", color: .yellow)
            case .done:
                Chip(text: "Done", color: .green)
            case .idle:
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let since = context.date.timeIntervalSince(session.lastActivity)
                    Text(Format.span(since) + " ago")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .accessibilityLabel("Last active \(Spoken.duration(since)) ago")
                }
            }
        }
        .monospacedDigit()
    }
}

/// Which side of the usage panel is up. Kept for the session only: limits come back first
/// after a relaunch, since they're what most people look for.
private final class UsagePaneChoice: ObservableObject {
    static let shared = UsagePaneChoice()
    @Published var showsCost = false
}

/// Limits as rings (Claude Code on top, Codex below), or turned over: estimated cost and the
/// last 30 days. The window never resizes, so both sides share the same box and scroll.
private struct UsagePanel: View {
    @EnvironmentObject private var model: IslandModel
    @ObservedObject private var pane = UsagePaneChoice.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.showClaude && !model.showCodex {
                UsageOff()
            } else {
                ScrollView {
                    Group {
                        if pane.showsCost {
                            CostPane()
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                if model.showClaude { ClaudeUsage() }
                                if model.showClaude && model.showCodex { Divider().overlay(.white.opacity(0.08)) }
                                if model.showCodex { CodexUsage() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }
                .scrollIndicators(.never)
                UsageFlip(showsCost: pane.showsCost) {
                    withAnimation(Motion.animation(.easeInOut(duration: 0.2))) { pane.showsCost.toggle() }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

private struct ProviderTitle: View {
    let kind: AgentKind
    let detail: String?
    /// When the account in use runs out at this pace, before its limit resets.
    var runsOut: Date? = nil

    var body: some View {
        HStack(spacing: 6) {
            AgentGlyph(kind: kind, size: 9)
                .frame(width: 14, height: 14)
            Text(kind.displayName).font(.system(size: 11, weight: .bold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let runsOut {
                Text("Runs out \(TaskTime.short(runsOut))").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                    .lineLimit(1).fixedSize().help("At this pace, its limit runs out before it resets")
            }
            if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).privacySensitive() }
        }
    }
}

private struct ClaudeUsage: View {
    @EnvironmentObject private var model: IslandModel

    /// The limits of the account in use. Once LiveIsland knows several accounts, only numbers
    /// filed under the active one count: right after a switch the status line still shows the
    /// previous account's until Claude answers on the new one. 5 hours only when the account
    /// has that limit; models' own weeks come from claude-swap.
    private var activeWindows: [RateLimitWindow]? {
        if model.accounts.count > 1 {
            let windows = model.accountsState.active?.windows ?? []
            return windows.isEmpty ? nil : windows
        }
        return model.agents.claudeLimits.map { $0.windows + (model.accountsState.active?.models ?? []) }
    }

    /// Which account, when there's more than one; else today's tokens.
    private func detail(_ usage: UsageSummary?) -> String? {
        if model.accounts.count > 1, let active = model.accountsState.active {
            return active.identity.email.components(separatedBy: "@").first
        }
        return usage.map { "Today \(Format.tokens($0.todayTokens))" }
    }

    var body: some View {
        let usage = model.agents.usage
        VStack(alignment: .leading, spacing: 8) {
            ProviderTitle(kind: .claude, detail: detail(usage), runsOut: model.limitForecast(.claude))
            if let windows = activeWindows {
                RingGauges(windows: windows, tint: AgentGlyph(kind: .claude).color)
            } else if let limit = model.agents.claudeLimit {
                HStack(spacing: 10) {
                    Ring(fraction: 1, color: .red, size: 40) { Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(.red) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(limit.windowLabel) limit reached").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        Text("Resets \(Format.until(limit.resetsAt))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(limit.windowLabel) limit reached")
                .accessibilityValue("100% used, resets in \(Spoken.duration(limit.resetsAt.timeIntervalSinceNow))")
            } else if let usage {
                HStack(spacing: 10) {
                    let fraction = usage.windowStart.map { min(1, Date().timeIntervalSince($0) / (5 * 3600)) } ?? 0
                    Ring(fraction: fraction, color: AgentGlyph(kind: .claude).color, size: 40) {
                        Text(Format.tokens(usage.windowTokens)).font(.system(size: 9, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tokens this window")
                    .accessibilityValue("\(Format.tokens(usage.windowTokens)), \(Spoken.percent(fraction)) of the 5 hours gone")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.windowStart == nil ? "No use in 5 hours" : "Tokens this window").font(.system(size: 11, weight: .semibold))
                        Text(usage.windowEnd.map { "Window ends \(Format.until($0))" } ?? "\(usage.todayRequests) replies today")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        Button { model.openSettings(.agents) } label: {
                            Text("Show limits in %").font(.system(size: 10, weight: .semibold)).foregroundStyle(AgentGlyph(kind: .claude).color)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

private struct CodexUsage: View {
    @EnvironmentObject private var model: IslandModel

    /// With several Codex accounts, only numbers filed under the one in use.
    private var activeWindows: [RateLimitWindow]? {
        if model.codexAccounts.count > 1 {
            let windows = model.accountsState.activeCodex?.windows ?? []
            return windows.isEmpty ? nil : windows
        }
        guard let windows = model.agents.codexLimits?.windows, !windows.isEmpty else { return nil }
        return windows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderTitle(kind: .codex, detail: model.codexAccounts.count > 1
                          ? model.accountsState.activeCodex?.identity.email.components(separatedBy: "@").first : nil,
                          runsOut: model.limitForecast(.codex))
            if let windows = activeWindows {
                RingGauges(windows: windows, tint: AgentGlyph(kind: .codex).color)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No recent sessions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Text("Run codex in a terminal: its limits show here after its first reply.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Both agents are turned off: say where to turn them on instead of showing an empty box.
private struct UsageOff: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 20)).foregroundStyle(.white.opacity(0.4))
            Text("Limits are off").font(.system(size: 12, weight: .semibold))
            Text("Turn on Claude Code or Codex to see their limits and cost here.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.openSettings(.agents) } label: {
                Text("Open AI Agents Settings").font(.system(size: 10, weight: .semibold)).foregroundStyle(AgentGlyph(kind: .claude).color)
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's last line: today's total, which turns the panel over to cost and history.
private struct UsageFlip: View {
    @EnvironmentObject private var model: IslandModel
    let showsCost: Bool
    let flip: () -> Void

    private var today: String? {
        if model.showClaude, let usage = model.agents.usage {
            return "\(Format.cost(usage.todayCost)) today"
        }
        if model.showCodex, let tokens = model.agents.codexTodayTokens {
            return "\(Format.tokens(tokens)) tokens today"
        }
        return nil
    }

    var body: some View {
        Button(action: flip) {
            HStack(spacing: 4) {
                if showsCost {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold))
                    Text("Limits")
                    Spacer(minLength: 0)
                } else {
                    Text(today ?? "Cost and history").monospacedDigit()
                    Spacer(minLength: 0)
                    Text("History")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(showsCost ? "Show the usage limits" : "Show estimated cost and the last 30 days")
        .accessibilityLabel(showsCost ? "Show the usage limits" : "Show estimated cost and history")
        .accessibilityValue(showsCost ? "" : today ?? "")
    }
}

/// Estimated cost and token use: today, this window, the last 30 days and where they went.
private struct CostPane: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showClaude { ClaudeCost() }
            if model.showClaude && model.showCodex { Divider().overlay(.white.opacity(0.08)) }
            if model.showCodex { CodexCost() }
        }
    }
}

private struct ClaudeCost: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let tint = AgentGlyph(kind: .claude).color
        VStack(alignment: .leading, spacing: 8) {
            ProviderTitle(kind: .claude, detail: "Estimated")
                .help("What the same use would cost at API list prices. A subscription isn't billed per token.")
            if let usage = model.agents.usage {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Format.cost(usage.todayCost)).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("today · \(usage.todayRequests) replies").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(usage.windowStart == nil ? "–" : Format.cost(usage.windowCost))
                            .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("this window").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                TokenKinds(counts: usage.today)
                let report = UsageReport(history: model.agents.usageHistory)
                HistoryLine(title: "30 days", total: report.trendIsCost ? Format.cost(report.cost) : "\(Format.tokens(report.tokens)) tokens",
                            levels: report.trend, tint: tint, empty: report.isEmpty)
                if !report.isEmpty {
                    Breakdown(title: "Models", slices: report.models, byCost: report.trendIsCost, tint: tint)
                    Breakdown(title: "Projects", slices: report.projects, byCost: report.trendIsCost, tint: tint).privacySensitive()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

private struct CodexCost: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let history = model.agents.codexHistory
        let total = history.reduce(0) { $0 + $1.tokens }
        VStack(alignment: .leading, spacing: 8) {
            ProviderTitle(kind: .codex, detail: "Tokens")
            if let today = model.agents.codexTodayTokens {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Format.tokens(today)).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("tokens today").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                }
                HistoryLine(title: "30 days", total: "\(Format.tokens(total)) tokens", levels: UsageReport.levels(codex: history),
                            tint: AgentGlyph(kind: .codex).color, empty: total == 0)
            } else {
                Text("No recent sessions").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Today's tokens by kind: cache reads are usually most of them but cost the least, so a
/// single sum would say little.
private struct TokenKinds: View {
    let counts: TokenCounts

    var body: some View {
        let kinds = [("In", counts.input), ("Out", counts.output), ("Cache write", counts.cacheWrite), ("Cache read", counts.cacheRead)]
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(kinds[(row * 2)..<(row * 2 + 2)], id: \.0) { kind in
                        HStack(spacing: 4) {
                            Text(kind.0).foregroundStyle(.white.opacity(0.45))
                            Spacer(minLength: 2)
                            Text(Format.tokens(kind.1)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// "30 days  $84" over a day-by-day bar sparkline.
private struct HistoryLine: View {
    let title: String
    let total: String
    let levels: [Double]
    let tint: Color
    let empty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                Text(total).monospacedDigit()
            }
            .font(.system(size: 9, weight: .semibold))
            if empty {
                // Old transcripts are never read in full, so history starts when LiveIsland does.
                Text("History builds up from the day LiveIsland started counting.")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
            } else {
                Sparkline(levels: levels, tint: tint).frame(height: 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(total)")
    }
}

/// A bar per day, today brightest. Plain shapes, drawn once per change: nothing moves.
private struct Sparkline: View {
    let levels: [Double]
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            DayBars(levels: levels, only: nil).fill(tint.opacity(0.45))
            DayBars(levels: levels, only: levels.count - 1).fill(tint)
        }
    }
}

/// The bars as one path: a day with any use is at least 1.5 points tall, so it shows.
private struct DayBars: Shape {
    let levels: [Double]
    /// Only this day's bar (today, drawn on top), or every bar but the last when nil.
    let only: Int?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !levels.isEmpty else { return path }
        let slot = rect.width / CGFloat(levels.count)
        let gap = min(1.5, slot * 0.3)
        for (index, level) in levels.enumerated() where level > 0 {
            if let only { guard index == only else { continue } } else if index == levels.count - 1 { continue }
            let height = max(1.5, rect.height * CGFloat(min(level, 1)))
            let bar = CGRect(x: rect.minX + CGFloat(index) * slot, y: rect.maxY - height, width: max(0.5, slot - gap), height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 0.75, height: 0.75))
        }
        return path
    }
}

/// Where the last 30 days went: a line per model or project, with its share as a thin bar.
private struct Breakdown: View {
    let title: String
    let slices: [UsageReport.Slice]
    let byCost: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            ForEach(slices) { slice in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(slice.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(byCost ? Format.cost(slice.cost) : Format.tokens(slice.tokens)).monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    ShareBar(share: slice.share, color: tint.opacity(slice.name == "Other" ? 0.4 : 0.85))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A thin track filled to `share`, as a shape so it needs no layout pass of its own.
private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.08))
            Capsule().fill(color).scaleEffect(x: CGFloat(min(max(share, 0.01), 1)), y: 1, anchor: .leading)
        }
        .frame(height: 2.5)
    }
}

/// Two rings to a row: the panel is too narrow for a third (5 hours, the week and a model's week).
private struct RingGauges: View {
    let windows: [RateLimitWindow]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: windows.count, by: 2)), id: \.self) { start in
                HStack(spacing: 0) {
                    ForEach(windows[start..<min(start + 2, windows.count)]) { window in
                        RingGauge(window: window, tint: tint).frame(maxWidth: .infinity)
                    }
                    // A lone ring keeps its column instead of taking the row's middle.
                    if windows.count - start == 1, windows.count > 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
    }
}

private struct RingGauge: View {
    let window: RateLimitWindow
    let tint: Color

    var body: some View {
        let used = min(max(window.usedPercent, 0), 100)
        HStack(spacing: 7) {
            Ring(fraction: used / 100, color: color(used), size: 36) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(used.rounded()))").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 7, weight: .bold, design: .rounded))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(window.model == nil && window.windowMinutes != 300 ? window.label : window.shortLabel)
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(window.resetsAt.map { Format.until($0) } ?? "Fresh").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        // The ring, its number and the reset as one gauge: "Week limit, 42% used, resets in 3 days".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.model == nil && window.windowMinutes != 300 ? window.label : window.shortLabel) limit")
        .accessibilityValue("\(Int(used.rounded()))% used"
                            + (window.resetsAt.map { ", resets in \(Spoken.duration($0.timeIntervalSinceNow))" } ?? ""))
    }

    private func color(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? .orange : tint
    }
}

struct Ring<Label: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    let color: Color
    var size: CGFloat = 40
    var lineWidth: CGFloat = 4.5
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center, startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 3)
            label
        }
        .frame(width: size, height: size)
        .animation(Motion.animation(.spring(response: 0.6, dampingFraction: 0.8), reduced: reduceMotion), value: fraction)
    }
}

// MARK: - Activity

private struct ActivityPage: View {
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                TimerTile()
                CalendarTile()
                BatteryTile()
            }
            GridRow {
                HeadphonesTile()
                MicrophoneTile()
                CameraTile()
            }
        }
    }
}

/// A Settings-style colored square with a white symbol.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

private struct Tile<Accessory: View, Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconBadge(symbol: symbol, tint: tint)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
            }
            content
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

extension Tile where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, tint: tint, title: title, accessory: { EmptyView() }, content: content)
    }
}

private struct TimerTile: View {
    @EnvironmentObject private var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var dial = TimerDial.shared

    var body: some View {
        Tile(symbol: "timer", tint: .orange, title: "Timer") {
            if model.timer != nil {
                HStack(spacing: 4) {
                    small(model.timer?.isPaused == true ? "play.fill" : "pause.fill",
                          label: model.timer?.isPaused == true ? "Resume timer" : "Pause timer") { model.toggleTimerPause() }
                    small("xmark", label: "Cancel timer") { model.cancelTimer() }
                }
            } else if dial.minutes != nil {
                small("xmark", label: "Back to the presets") { dial.clear() }
            }
        } content: {
            if let timer = model.timer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 10) {
                        Ring(fraction: 1 - timer.progress(at: context.date), color: .orange, size: 42, lineWidth: 4) {
                            Image(systemName: timer.isPaused ? "pause.fill" : "hourglass").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                        }
                        Text(Format.clock(timer.remaining(at: context.date)))
                            .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                            .minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(timer.isPaused ? "Timer, paused" : "Timer")
                    .accessibilityValue("\(Spoken.duration(timer.remaining(at: context.date))) left")
                }
            } else if model.timerFinished {
                Button { model.dismissTimerAlert() } label: {
                    Label("Time's up", systemImage: "bell.fill").font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(PressableStyle())
            } else if let minutes = dial.minutes {
                VStack(alignment: .leading, spacing: 5) {
                    Text(TimerLength.label(minutes))
                        .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText(value: minutes))
                        .animation(Motion.animation(.snappy(duration: 0.2), reduced: reduceMotion), value: minutes)
                    Button {
                        model.startTimer(minutes: minutes)
                        dial.clear()
                    } label: {
                        Label("Start", systemImage: "play.fill").font(.system(size: 11, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(Capsule().fill(.orange.opacity(0.16)))
                            .foregroundStyle(.orange)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                    ForEach([1.0, 5, 10, 25], id: \.self) { minutes in
                        Button { model.startTimer(minutes: minutes) } label: {
                            Text("\(Int(minutes)) min").font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(Capsule().fill(.orange.opacity(0.16)))
                                .foregroundStyle(.orange)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Start a \(Spoken.count(Int(minutes), "minute", "minutes")) timer")
                    }
                }
            }
        }
        // Scrolling picks any length without typing, so the island never needs the keyboard.
        // Only while no timer runs: a stray scroll shouldn't change one counting down.
        .background(ScrollCatcher(isActive: model.timer == nil && !model.timerFinished) { delta, precise in
            dial.scroll(delta, precise: precise)
        })
        .help(model.timer == nil ? "Scroll to pick any length" : "")
        .onDisappear { dial.clear() }
    }

    private func small(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.1))).contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The length being picked by scrolling over the timer tile. Lives outside the view, since
/// SwiftUI's @State needs Xcode's plugins; nil shows the presets.
@MainActor
private final class TimerDial: ObservableObject {
    static let shared = TimerDial()
    @Published private(set) var minutes: Double?
    private var steps = ScrollSteps()

    func scroll(_ delta: Double, precise: Bool) {
        let count = steps.add(delta, precise: precise)
        guard count != 0 else { return }
        let next = TimerLength.step(minutes ?? TimerLength.initial, by: count)
        guard next != minutes else { return }
        minutes = next
        // A light tick per step on a Force Touch trackpad, like a picker wheel.
        if precise { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    func clear() {
        if minutes != nil { minutes = nil }
        steps.reset()
    }
}

/// Hands scroll-wheel events over its own bounds to `onScroll`, signed so that fingers or the
/// wheel moving up mean "more" (natural scrolling is flipped back). It listens with a local
/// monitor only while it's on screen and active, so idle costs nothing, and it never takes
/// clicks from the buttons above it.
private struct ScrollCatcher: NSViewRepresentable {
    var isActive: Bool
    var onScroll: (Double, Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.isActive = isActive
    }

    final class CatcherView: NSView {
        var isActive = false { didSet { if isActive != oldValue { updateMonitor() } } }
        var onScroll: ((Double, Bool) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            let wanted = isActive && window != nil
            if wanted, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, self.handle(event) else { return event }
                    return nil
                }
            } else if !wanted, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        /// True when the scroll was over this view, and so is used up here.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            // Momentum after the fingers lift would keep counting after the person stopped.
            guard event.momentumPhase.isEmpty else { return true }
            let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            let delta = vertical ? event.scrollingDeltaY : -event.scrollingDeltaX
            onScroll?(Double(event.isDirectionInvertedFromDevice ? -delta : delta), event.hasPreciseScrollingDeltas)
            return true
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct CalendarTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Tile(symbol: "calendar", tint: .red, title: Date().formatted(.dateTime.weekday(.wide).day())) {
            let upcoming = Array(model.events.prefix(2))
            if upcoming.isEmpty {
                Text("No more events").font(.system(size: 13, weight: .semibold))
                Text("Enjoy the free time").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(upcoming) { event in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5).fill(event.color.map(Color.init(cgColor:)) ?? .red).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).privacySensitive()
                                TimelineView(.everyMinute) { context in
                                    Text(event.start > context.date
                                         ? "\(event.start.formatted(date: .omitted, time: .shortened)) · \(Format.until(event.start, from: context.date))"
                                         : "Now · until \(event.end.formatted(date: .omitted, time: .shortened))")
                                }
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            JoinButton(event: event)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Join, from shortly before a call starts until it ends: earlier, the tile stays calm.
private struct JoinButton: View {
    @EnvironmentObject private var model: IslandModel
    let event: CalendarProvider.Event

    var body: some View {
        let now = Date()
        if let link = model.meetingLink(for: event), event.end > now, event.start.timeIntervalSince(now) < ClockTicks.eventLead {
            Button { model.joinMeeting(link.url) } label: {
                Text("Join").font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8).frame(height: 18)
                    .background(Capsule().fill(.green))
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("Join on \(link.service.name)")
            .accessibilityLabel("Join on \(link.service.name)")
        }
    }
}

private struct BatteryTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let battery = model.system.battery
        Tile(symbol: "bolt.fill", tint: .green, title: "Battery") {
            if let battery {
                HStack(alignment: .center, spacing: 10) {
                    Text("\(battery.percent)%").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    BatteryGlyph(percent: battery.percent, charging: battery.isCharging || battery.onPower, width: 34)
                        .accessibilityHidden(true)
                }
                Text(detail(battery)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            } else {
                Text("Desktop power").font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func detail(_ battery: SystemMonitor.Battery) -> String {
        let time = battery.minutesRemaining.map { Format.span(TimeInterval($0 * 60)) }
        if battery.isCharging { return time.map { "Charging · full in \($0)" } ?? "Charging" }
        if battery.onPower { return "On power" }
        return time.map { "\($0) left" } ?? "On battery"
    }
}

private struct HeadphonesTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let headphones = model.system.headphones
        Tile(symbol: headphones.map { HeadphoneSymbol.name(for: $0.name) } ?? "headphones", tint: .blue,
             title: headphones?.connected == true ? headphones!.name : "Headphones") {
            if let headphones, headphones.connected {
                HStack(spacing: 10) {
                    if let left = headphones.left { level("L", left) }
                    if let right = headphones.right { level("R", right) }
                    if let single = headphones.single { level("", single) }
                    if let caseLevel = headphones.caseLevel { level("Case", caseLevel) }
                    if headphones.summary == nil && headphones.caseLevel == nil {
                        Text("Connected").font(.system(size: 13, weight: .semibold))
                    }
                }
            } else {
                Text("Not connected").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                if let output = model.output {
                    Text("Sound: \(output.device)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
        }
    }

    private func level(_ label: String, _ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(percent)%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(percent <= 20 ? .red : .white)
            Capsule().fill(.white.opacity(0.15)).frame(width: 30, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(percent <= 20 ? Color.red : .green).frame(width: 30 * CGFloat(percent) / 100, height: 3)
                }
            if !label.isEmpty { Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSide(label))
        .accessibilityValue("\(percent)%")
    }

    private static func spokenSide(_ label: String) -> String {
        switch label {
        case "L": return "Left"
        case "R": return "Right"
        case "": return "Battery"
        default: return label
        }
    }
}

private struct MicrophoneTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        let call = model.system.call
        let apps = model.system.microphoneApps
        Tile(symbol: call != nil ? "phone.fill" : "mic.fill", tint: call != nil ? .green : .orange,
             title: call != nil ? "Call" : "Microphone", accessory: {
            if call != nil { MicMuteButton(microphone: model.microphone) }
        }) {
            if let call {
                Text(call.app).font(.system(size: 14, weight: .bold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(context.date.timeIntervalSince(call.since))).monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.green)
            } else if let app = apps.first {
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                    Text(app).font(.system(size: 14, weight: .bold)).lineLimit(1)
                }
                Text(apps.count > 1 ? "+\(apps.count - 1) more listening" : "Listening now")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            } else {
                Text("Off").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                Text("No app is listening").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

/// Mutes the Mac's microphone for the call; red while muted. LiveIsland gives the sound back
/// when the call ends.
private struct MicMuteButton: View {
    @ObservedObject var microphone: MicrophoneMute

    var body: some View {
        if let state = microphone.state {
            Button { microphone.toggle() } label: {
                Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(state.muted ? .white : .white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(state.muted ? Color.red : Color.white.opacity(0.14)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help(state.muted ? "Unmute \(state.device)" : "Mute \(state.device)")
            .accessibilityLabel(state.muted ? "Unmute \(state.device)" : "Mute \(state.device)")
        }
    }
}

private struct CameraTile: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        Tile(symbol: "video.fill", tint: model.system.cameraOn ? .green : .gray, title: "Camera") {
            if model.system.cameraOn {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("In use").font(.system(size: 14, weight: .bold))
                }
                Text("An app is using the camera").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            } else {
                Text("Off").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                Text("Nothing is watching").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

// MARK: - Shared

/// Where apps live, their icons and names, looked up once. Views ask on every redraw, and each
/// Launch Services lookup is a trip to another process, so missing apps are remembered too.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    /// Misses expire after 10 minutes, or as soon as any app launches (one just installed, say);
    /// hits after an hour, in case an app was moved or deleted.
    private static var urls = LookupCache<String, URL>(hitLifetime: 3600, missLifetime: 600)
    private static var launchObserver: NSObjectProtocol?

    /// Where the app is installed, or nil when it isn't.
    static func url(_ bundleIdentifier: String) -> URL? {
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { urls.forgetMisses() }
            }
        }
        return urls.value(for: bundleIdentifier, at: Date()) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    }

    static func icon(_ bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let icon = icons[bundleIdentifier] { return icon }
        guard let url = url(bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleIdentifier] = icon
        return icon
    }

    static func name(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if let name = names[bundleIdentifier] { return name }
        guard let url = url(bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleIdentifier] = name
        return name
    }
}

/// Plain buttons that dip slightly when pressed; under Reduce Motion they only dim.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(label: configuration.label, isPressed: configuration.isPressed)
    }

    /// A view of its own, where the environment's Reduce Motion can be read.
    private struct Pressed<Label: View>: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let label: Label
        let isPressed: Bool

        var body: some View {
            label
                .scaleEffect(isPressed && !reduceMotion ? 0.88 : 1)
                .opacity(isPressed ? 0.7 : 1)
                .animation(Motion.animation(.spring(response: 0.2, dampingFraction: 0.7), reduced: reduceMotion), value: isPressed)
        }
    }
}
