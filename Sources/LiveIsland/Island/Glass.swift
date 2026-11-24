import SwiftUI

/// Liquid Glass on macOS 26 and later, with a material fallback for earlier systems.
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Sing With Me's glass: real Liquid Glass on macOS 26, frosted or clear, tinted with the
/// card's colour. Earlier systems get a plain tint here; the card's window adds a blur
/// behind it, and Settings' preview a material.
extension View {
    @ViewBuilder
    func lyricsGlass<S: Shape>(clear: Bool, tint: Color, in shape: S, interactive: Bool = false,
                               materialFallback: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive), in: shape)
        } else if materialFallback {
            background(shape.fill(tint)).background(clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
        } else {
            background(shape.fill(tint))
        }
    }
}

/// Whether this Mac draws Liquid Glass.
enum LiquidGlass {
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}
