import CoreGraphics
import Foundation

/// The sizes Sing With Me's window comes in. Each hangs from the top of the screen, like the
/// island; "custom" is wherever the person dragged it.
public enum LyricsPreset: String, CaseIterable, Identifiable, Sendable {
    case band
    case fullScreen
    case wideIsland
    case compact
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .band: return "Full-width band"
        case .fullScreen: return "Full screen"
        case .wideIsland: return "Wide island"
        case .compact: return "Compact card"
        case .custom: return "Custom"
        }
    }

    public var symbol: String {
        switch self {
        case .band: return "rectangle.topthird.inset.filled"
        case .fullScreen: return "rectangle.inset.filled"
        case .wideIsland: return "capsule"
        case .compact: return "rectangle.center.inset.filled"
        case .custom: return "hand.draw"
        }
    }
}

/// Where Sing With Me's window goes on one display: a preset, or the frame the person dragged,
/// kept relative to the display's bottom-left corner so it survives another arrangement.
public struct LyricsPlacement: Equatable, Sendable {
    public var preset: LyricsPreset
    /// Only for `.custom`.
    public var frame: CGRect?

    public init(preset: LyricsPreset, frame: CGRect? = nil) {
        self.preset = preset == .custom && frame == nil ? .band : preset
        self.frame = self.preset == .custom ? frame : nil
    }

    public static let standard = LyricsPlacement(preset: .band)

    /// "band", "compact", or "custom:x,y,w,h"; anything else is the standard band.
    public init(saved: String?) {
        guard let saved else { self = .standard; return }
        if saved.hasPrefix("custom:") {
            let numbers = saved.dropFirst("custom:".count).split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { self = .standard; return }
            self.init(preset: .custom, frame: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        } else {
            self.init(preset: LyricsPreset(rawValue: saved) ?? .band)
        }
    }

    public var saved: String {
        guard preset == .custom, let frame else { return preset.rawValue }
        return "custom:\(Double(frame.minX)),\(Double(frame.minY)),\(Double(frame.width)),\(Double(frame.height))"
    }
}

/// The window's frame for a preset, and the limits a drag or a typed size stays within.
public enum LyricsGeometry {
    public static let minimumSize = CGSize(width: 360, height: 160)
    public static let compactSize = CGSize(width: 520, height: 220)
    public static let wideIslandHeight: CGFloat = 140
    public static let bandFraction: CGFloat = 0.4

    /// The room it may take: the whole width, from the Dock up to the very top (it hangs from
    /// the notch, over the menu bar).
    public static func bounds(screen: CGRect, visible: CGRect) -> CGRect {
        let bottom = max(screen.minY, min(visible.minY, screen.maxY - minimumSize.height))
        return CGRect(x: screen.minX, y: bottom, width: screen.width, height: screen.maxY - bottom)
    }

    /// The frame in global coordinates. `notch` centres the compact card under the camera.
    public static func frame(for placement: LyricsPlacement, screen: CGRect, visible: CGRect, notch: CGRect?) -> CGRect {
        let bounds = bounds(screen: screen, visible: visible)
        let centre = notch?.midX ?? screen.midX
        func hanging(width: CGFloat, height: CGFloat, centredOn x: CGFloat) -> CGRect {
            clamp(CGRect(x: x - width / 2, y: bounds.maxY - height, width: width, height: height), to: bounds)
        }
        switch placement.preset {
        case .band: return hanging(width: bounds.width, height: (screen.height * bandFraction).rounded(), centredOn: bounds.midX)
        case .fullScreen: return bounds
        case .wideIsland: return hanging(width: bounds.width, height: wideIslandHeight, centredOn: bounds.midX)
        case .compact: return hanging(width: compactSize.width, height: compactSize.height, centredOn: centre)
        case .custom:
            guard let saved = placement.frame else { return frame(for: .standard, screen: screen, visible: visible, notch: notch) }
            return clamp(saved.offsetBy(dx: screen.minX, dy: screen.minY), to: bounds)
        }
    }

    /// `rect` at least the minimum size and at most `bounds`, moved (not shrunk further) to
    /// lie inside it.
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumSize.width), bounds.width)
        let height = min(max(rect.height, minimumSize.height), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    /// Which edges a drag moves: one or two of them, or none to move the whole window.
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let bottom = Edges(rawValue: 4)
        public static let top = Edges(rawValue: 8)
    }

    /// The edges under a point `inset` points or less from the window's sides, in the window's
    /// own coordinates (origin bottom-left).
    public static func edges(at point: CGPoint, in size: CGSize, inset: CGFloat = 6) -> Edges {
        var edges: Edges = []
        if point.x <= inset { edges.insert(.left) } else if point.x >= size.width - inset { edges.insert(.right) }
        if point.y <= inset { edges.insert(.bottom) } else if point.y >= size.height - inset { edges.insert(.top) }
        // Corners are easier to grab: a wider band near them.
        let corner = inset * 3
        if edges.contains(.left) || edges.contains(.right) {
            if point.y <= corner { edges.insert(.bottom) } else if point.y >= size.height - corner { edges.insert(.top) }
        }
        if edges.contains(.bottom) || edges.contains(.top) {
            if point.x <= corner { edges.insert(.left) } else if point.x >= size.width - corner { edges.insert(.right) }
        }
        return edges
    }

    /// `start` with `edges` dragged by `delta`, never under the minimum size (the opposite edge
    /// stays put) nor outside `bounds`.
    public static func resize(_ start: CGRect, edges: Edges, by delta: CGSize, within bounds: CGRect) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = min(max(start.minX + delta.width, bounds.minX), maxX - minimumSize.width) }
        if edges.contains(.right) { maxX = max(min(start.maxX + delta.width, bounds.maxX), minX + minimumSize.width) }
        if edges.contains(.bottom) { minY = min(max(start.minY + delta.height, bounds.minY), maxY - minimumSize.height) }
        if edges.contains(.top) { maxY = max(min(start.maxY + delta.height, bounds.maxY), minY + minimumSize.height) }
        return clamp(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: bounds)
    }

    /// The window at a typed size: the same top edge and centre, inside `bounds`.
    public static func sized(_ rect: CGRect, width: CGFloat, height: CGFloat, within bounds: CGRect) -> CGRect {
        let next = CGRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height)
        return clamp(next, to: bounds)
    }
}

/// Where the header's controls go, so none sits under the camera: beside the notch when the
/// window's top runs behind it and there's room on both sides, else just below it.
public struct LyricsHeaderLayout: Equatable, Sendable {
    /// How far down the header starts.
    public var topInset: CGFloat
    /// Room for the track (left) and the buttons (right); the gap between them is the notch's.
    public var leadingWidth: CGFloat
    public var trailingWidth: CGFloat
    /// Where the camera's gap starts and how wide it is, in the window's coordinates; nil when
    /// the header doesn't meet the notch.
    public var gap: ClosedRange<CGFloat>?
    /// How tall the header is: at least `LyricsTypography.headerHeight`, and beside the camera
    /// at least as tall as the part of the window it hides, so the words start below it.
    public var height: CGFloat

    public static let margin: CGFloat = 10
    public static let leastLeading: CGFloat = 150
    public static let leastTrailing: CGFloat = 96

    /// `panel` and `notch` in the same global coordinates (origin bottom-left).
    public init(panel: CGRect, notch: CGRect?) {
        guard let notch, notch.width > 0, panel.maxY > notch.minY, panel.minY < notch.maxY,
              notch.maxX > panel.minX, notch.minX < panel.maxX else {
            self.init(topInset: 0, leadingWidth: panel.width, trailingWidth: panel.width, gap: nil)
            return
        }
        let start = max(0, notch.minX - panel.minX - Self.margin)
        let end = min(panel.width, notch.maxX - panel.minX + Self.margin)
        let leading = start, trailing = panel.width - end
        if leading >= Self.leastLeading, trailing >= Self.leastTrailing {
            self.init(topInset: 0, leadingWidth: leading, trailingWidth: trailing, gap: start...end,
                      height: max(LyricsTypography.headerHeight, panel.maxY - notch.minY))
        } else {
            // Too little room beside the camera: the whole header goes under it.
            self.init(topInset: max(0, panel.maxY - notch.minY), leadingWidth: panel.width, trailingWidth: panel.width, gap: nil)
        }
    }

    public init(topInset: CGFloat, leadingWidth: CGFloat, trailingWidth: CGFloat, gap: ClosedRange<CGFloat>?,
                height: CGFloat = LyricsTypography.headerHeight) {
        self.topInset = topInset
        self.leadingWidth = leadingWidth
        self.trailingWidth = trailingWidth
        self.gap = gap
        self.height = height
    }
}

/// How big the words are: with the window, times the person's own multiplier.
public enum LyricsTypography {
    public static let headerHeight: CGFloat = 44
    public static let scaleRange: ClosedRange<Double> = 0.6...2

    public static func fontSize(panel: CGSize, scale: Double) -> CGFloat {
        let room = max(0, panel.height - headerHeight)
        let base = min(max(min(room * 0.11, panel.width * 0.045), 16), 64)
        let scale = min(max(scale.isFinite ? scale : 1, scaleRange.lowerBound), scaleRange.upperBound)
        return (base * CGFloat(scale)).rounded()
    }

    /// Where the current line sits, from the top of the lyrics (0) to the bottom (1): a third
    /// of the way down, or near the top when only a few lines fit.
    public static func anchor(height: CGFloat) -> CGFloat {
        height < 240 ? 0.08 : 0.33
    }
}

/// The timing offset the person sets when the words drift from the song.
public enum LyricsOffset {
    public static let step: Double = 0.1
    public static let range: ClosedRange<Double> = -10...10

    /// `value` moved by `steps` tenths of a second, rounded to a tenth, within ±10 s.
    public static func stepped(_ value: Double, by steps: Int) -> Double {
        let next = ((value + Double(steps) * step) * 10).rounded() / 10
        return min(max(next, range.lowerBound), range.upperBound)
    }

    /// "On time", "0.3 s sooner", "1.2 s later".
    public static func label(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        if tenths == 0 { return "On time" }
        return String(format: "%.1f s %@", abs(tenths), tenths > 0 ? "sooner" : "later")
    }
}

/// Which side the words line up on.
public enum LyricsAlignment: String, CaseIterable, Identifiable, Sendable {
    case left
    case center

    public var id: String { rawValue }
    public var title: String { self == .left ? "Left" : "Centre" }
}
