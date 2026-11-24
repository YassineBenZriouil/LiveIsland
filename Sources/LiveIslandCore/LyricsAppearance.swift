import Foundation

/// A colour as Sing With Me saves it: sRGB components from 0 to 1.
public struct LyricsColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try container.decode(Double.self, forKey: .red), green: try container.decode(Double.self, forKey: .green),
                  blue: try container.decode(Double.self, forKey: .blue),
                  alpha: try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1)
    }

    public static let white = LyricsColor(red: 1, green: 1, blue: 1)
    public static let black = LyricsColor(red: 0, green: 0, blue: 0)

    /// Relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public var isLight: Bool { luminance > 0.45 }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 1 }
}

/// How Sing With Me's card looks: every choice in one value, saved as one setting. Anything
/// missing or unreadable in a saved value takes its default, and every number is kept in range.
public struct LyricsAppearance: Codable, Equatable, Sendable {
    public enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The cover's colour, deepened.
        case artwork
        case dark
        case light
        case custom

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .artwork: return "From the cover"
            case .dark: return "Dark"
            case .light: return "Light"
            case .custom: return "Custom"
            }
        }
    }

    public enum Weight: String, Codable, CaseIterable, Identifiable, Sendable {
        case regular, semibold, bold, heavy
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    /// How the line being sung stands out.
    public enum Highlight: String, Codable, CaseIterable, Identifiable, Sendable {
        /// It fills in, left to right, as it's sung, as in Spotify.
        case fill
        /// The whole line lights up at once.
        case line
        /// Every line looks the same.
        case off
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .fill: return "Fill as it's sung"
            case .line: return "Whole line"
            case .off: return "Off"
            }
        }
    }

    public enum LineAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
        case slideUp, fade, none
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .slideUp: return "Slide up"
            case .fade: return "Fade"
            case .none: return "None"
            }
        }
    }

    /// Liquid Glass's two looks.
    public enum GlassStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Frosted: what's behind is blurred.
        case regular
        /// See-through: what's behind stays sharp, bent at the edges.
        case clear

        public var id: String { rawValue }
        public var title: String { self == .regular ? "Frosted" : "Clear" }
    }

    public var glass: GlassStyle = .regular
    /// How strongly the glass is tinted with the background colour, 0 to 1.
    public var tint: Double = 0.4
    /// Where the tint comes from.
    public var background: Background = .artwork
    public var customColor: LyricsColor = LyricsColor(red: 0.2, green: 0.1, blue: 0.35)
    /// Times the size that fits the card.
    public var textScale: Double = 1
    public var weight: Weight = .bold
    /// The line being sung; nil picks white or black to suit the background.
    public var currentColor: LyricsColor?
    /// How much the other lines fade, 0 (as bright as the current one) to 1 (nearly gone).
    public var dimming: Double = 0.73
    public var highlight: Highlight = .fill
    public var alignment: LyricsAlignment = .center
    public var lines: LyricsLineCount = .three
    public var cornerRadius: Double = 16
    /// A soft shadow under the words. The glass has its own depth.
    public var shadow = true
    public var lineAnimation: LineAnimation = .slideUp
    public var position: LyricsPosition = .underNotch

    public static let cornerRange: ClosedRange<Double> = 0...40
    public static let standard = LyricsAppearance()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case glass, tint, background, customColor, textScale, weight, currentColor, dimming, highlight, alignment, lines
        case cornerRadius, shadow, lineAnimation, position
        // Values saved by earlier versions may also hold "border", "drift" and "edgeFade",
        // which are no longer settings, and "blur" and "opacity", which became the glass.
        case blur, opacity
    }

    /// The glass for a look saved before there was glass: a blur of at least a third was
    /// frosted, less was see-through; the background's opacity becomes the tint.
    public static func migrated(blur: Double?, opacity: Double?) -> (GlassStyle, Double) {
        let style: GlassStyle = (blur.map { $0.isFinite ? $0 : 1 } ?? 1) >= 0.35 ? .regular : .clear
        return (style, opacity.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } ?? standard.tint)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(glass, forKey: .glass)
        try c.encode(tint, forKey: .tint)
        try c.encode(background, forKey: .background)
        try c.encode(customColor, forKey: .customColor)
        try c.encode(textScale, forKey: .textScale)
        try c.encode(weight, forKey: .weight)
        try c.encodeIfPresent(currentColor, forKey: .currentColor)
        try c.encode(dimming, forKey: .dimming)
        try c.encode(highlight, forKey: .highlight)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(lines, forKey: .lines)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(lineAnimation, forKey: .lineAnimation)
        try c.encode(position, forKey: .position)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LyricsAppearance.standard
        // One bad value spoils only itself.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        if c.contains(.glass) || c.contains(.tint) {
            glass = value(.glass, d.glass)
            tint = value(.tint, d.tint)
        } else if c.contains(.blur) || c.contains(.opacity) {
            (glass, tint) = Self.migrated(blur: value(.blur, nil as Double?), opacity: value(.opacity, nil as Double?))
        }
        background = value(.background, d.background)
        customColor = value(.customColor, d.customColor)
        textScale = value(.textScale, d.textScale)
        weight = value(.weight, d.weight)
        currentColor = (try? c.decodeIfPresent(LyricsColor.self, forKey: .currentColor)) ?? nil
        dimming = value(.dimming, d.dimming)
        highlight = value(.highlight, d.highlight)
        alignment = value(.alignment, d.alignment)
        lines = value(.lines, d.lines)
        cornerRadius = value(.cornerRadius, d.cornerRadius)
        shadow = value(.shadow, d.shadow)
        lineAnimation = value(.lineAnimation, d.lineAnimation)
        position = value(.position, d.position)
        self = clamped()
    }

    /// Every number in its range; anything that isn't a number takes its default.
    public func clamped() -> LyricsAppearance {
        var copy = self
        let d = LyricsAppearance.standard
        func fit(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        copy.tint = fit(tint, 0...1, d.tint)
        copy.textScale = fit(textScale, LyricsTypography.scaleRange, d.textScale)
        copy.dimming = fit(dimming, 0...1, d.dimming)
        copy.cornerRadius = fit(cornerRadius, Self.cornerRange, d.cornerRadius)
        return copy
    }

    /// The saved form.
    public func encoded() -> Data? { try? JSONEncoder().encode(clamped()) }

    /// A saved value, or the defaults when there's none or it can't be read.
    public static func decode(_ data: Data?) -> LyricsAppearance {
        guard let data, let appearance = try? JSONDecoder().decode(LyricsAppearance.self, from: data) else { return .standard }
        return appearance
    }

    /// Whether the glass is tinted light enough to need dark words (only a light or a light
    /// custom tint that's strong enough to show).
    public var hasLightBackground: Bool {
        guard tint >= 0.35 else { return false }
        switch background {
        case .light: return true
        case .custom: return customColor.isLight
        case .artwork, .dark: return false
        }
    }

    /// The current line's colour: the chosen one, else white, or black on a light background.
    public var resolvedCurrentColor: LyricsColor {
        currentColor ?? (hasLightBackground ? .black : .white)
    }

    /// How bright the lines that aren't being sung are, from the dimming.
    public var otherLinesOpacity: Double { 1 - 0.85 * dimming }

    /// On clear, barely tinted glass the words sit on whatever is behind them: they keep a
    /// soft shadow, even with shadows off, so they stay readable.
    public var needsTextShadow: Bool { shadow || (glass == .clear && tint < 0.15) }

    /// Bigger or smaller words, by tenths, within range.
    public mutating func changeTextScale(by step: Double) {
        textScale = ((textScale + step) * 10).rounded() / 10
        self = clamped()
    }
}
