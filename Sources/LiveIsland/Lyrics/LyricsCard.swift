import AppKit
import LiveIslandCore
import SwiftUI

/// Sing With Me's way in, on the Media tab: a blurred card that fades out toward its sides,
/// with the line being sung. Tapping it opens the lyrics card. A song without words hides
/// it; while Sing With Me is off, a small chip offers it instead.
struct SingWithMeCard: View {
    @ObservedObject var sing: SingWithMe
    let accent: Color
    let hidesDetails: Bool
    let open: () -> Void

    var body: some View {
        if !LyricsVisibility.showsEntry(isEnabled: sing.isEnabled, lyrics: sing.lyrics) {
            EmptyView()
        } else if sing.isEnabled {
            CardFace(sing: sing, accent: accent, open: open)
                .redacted(reason: hidesDetails ? .privacy : [])
                .frame(minWidth: 90, maxWidth: 220)
                .frame(height: 26)
                .layoutPriority(-1)
                .transition(.opacity)
        } else {
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "music.mic").font(.system(size: 10, weight: .bold))
                    Text("Sing With Me").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("See the lyrics of the song playing")
            .accessibilityLabel("Sing With Me")
            .accessibilityHint("Shows the lyrics of the song playing, after asking")
        }
    }
}

/// The card itself: the icon and the line being sung, on glass that fades out at both ends.
private struct CardFace: View {
    @ObservedObject var sing: SingWithMe
    let accent: Color
    let open: () -> Void

    var body: some View {
        let text = sing.teaser ?? "♪"
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
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
}
