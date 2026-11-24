import AppKit
import LiveIslandCore
import QuartzCore
import SwiftUI

/// Sing With Me's way in, on the Media tab: a blurred card that fades out toward its sides,
/// with the line being sung, drifting gently while the song plays. Its icon opens the lyrics
/// window. While Sing With Me is off, a small chip offers it instead.
struct SingWithMeCard: View {
    @ObservedObject var sing: SingWithMe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playing: Bool
    let accent: Color
    let hidesDetails: Bool
    let open: () -> Void

    var body: some View {
        if sing.isEnabled {
            Drifting(active: playing && sing.appearance.drift && !reduceMotion, distance: 5) {
                CardFace(sing: sing, accent: accent, open: open)
                    .redacted(reason: hidesDetails ? .privacy : [])
            }
            .frame(minWidth: 90, maxWidth: 220)
            .frame(height: 26)
            .layoutPriority(-1)
        } else {
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "music.mic").font(.system(size: 10, weight: .bold))
                    Text("Sing With Me").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("See the lyrics of the song playing")
            .accessibilityLabel("Sing With Me")
            .accessibilityHint("Shows the lyrics of the song playing, after asking")
        }
    }
}

/// The card itself, drawn inside the drifting layer.
private struct CardFace: View {
    @ObservedObject var sing: SingWithMe
    let accent: Color
    let open: () -> Void

    var body: some View {
        let (text, quiet) = words
        let fade = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                          .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                  startPoint: .leading, endPoint: .trailing)
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: sing.isOpen ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.12)))
                Text(text)
                    .font(.system(size: 11, weight: quiet ? .medium : .semibold))
                    .foregroundStyle(.white.opacity(quiet ? 0.5 : 0.9))
                    .lineLimit(1)
                    .privacySensitive()
                    .id(text)
                    .transition(.opacity)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Blurred glass that gives way to nothing at both ends.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    LinearGradient(colors: [accent.opacity(0.22), .white.opacity(0.06), accent.opacity(0.22)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .mask(fade)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(.easeInOut(duration: 0.3), value: text)
        .help(sing.isOpen ? "Close Sing With Me" : "Sing With Me: show the lyrics")
        .accessibilityLabel(sing.isOpen ? "Close Sing With Me" : "Sing With Me")
        .accessibilityValue(text)
        .environment(\.colorScheme, .dark)
    }

    /// The words to show, and whether they're a quiet note rather than lyrics.
    private var words: (String, Bool) {
        switch sing.state {
        case .found(let lyrics):
            if lyrics.kind == .instrumental { return ("Instrumental ♪", true) }
            return (sing.teaser ?? "♪", false)
        case .missing: return ("No lyrics for this song", true)
        case .loading: return ("Looking for lyrics…", true)
        case .failed: return ("Lyrics unavailable right now", true)
        case .idle: return ("Sing With Me", true)
        }
    }
}

/// Moves its content gently side to side with a Core Animation loop, which the render server
/// plays without waking the app each frame; still when inactive.
struct Drifting<Content: View>: NSViewRepresentable {
    let active: Bool
    let distance: CGFloat
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> DriftView<Content> {
        DriftView(rootView: content())
    }

    func updateNSView(_ view: DriftView<Content>, context: Context) {
        view.host.rootView = content()
        view.setDrifting(active, distance: distance)
    }
}

final class DriftView<Content: View>: NSView {
    let host: FirstClickHostingView<Content>
    private var wanted = false
    private var distance: CGFloat = 7
    private static var key: String { "drift" }

    init(rootView: Content) {
        host = FirstClickHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sync()
    }

    func setDrifting(_ on: Bool, distance: CGFloat) {
        let changed = on != wanted || distance != self.distance
        wanted = on
        self.distance = distance
        if changed { host.layer?.removeAnimation(forKey: Self.key) }
        sync()
    }

    /// The loop runs only while wanted and in a window.
    private func sync() {
        guard let layer = host.layer else { return }
        guard wanted, window != nil else {
            layer.removeAnimation(forKey: Self.key)
            return
        }
        guard layer.animation(forKey: Self.key) == nil else { return }
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = -distance
        drift.toValue = distance
        drift.duration = 3.4
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.isAdditive = true
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(drift, forKey: Self.key)
    }
}
