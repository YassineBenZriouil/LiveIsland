import CoreGraphics
import Foundation

/// The sizes Sing With Me's card comes in. "Small" is the default: a little card just under
/// the notch. "Custom" is whatever the person dragged or typed.
public enum LyricsPreset: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case band
    case fullScreen
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .band: return "Wide band"
        case .fullScreen: return "Full screen"
        case .custom: return "Custom"
        }
    }

    public var symbol: String {
        switch self {
        case .small: return "capsule"
        case .medium: return "rectangle"
        case .band: return "rectangle.topthird.inset.filled"
        case .fullScreen: return "rectangle.inset.filled"
        case .custom: return "hand.draw"
        }
    }
}

/// Where Sing With Me's card goes on one display: a preset, or the frame the person dragged,
/// kept relative to the display's bottom-left corner so it survives another arrangement.
public struct LyricsPlacement: Equatable, Sendable {
    public var preset: LyricsPreset
    /// Only for `.custom`.
    public var frame: CGRect?

    public init(preset: LyricsPreset, frame: CGRect? = nil) {
        self.preset = preset == .custom && frame == nil ? .small : preset
        self.frame = self.preset == .custom ? frame : nil
    }

    public static let standard = LyricsPlacement(preset: .small)

    /// What the saved placements are written in. Version 1 placements were the old, huge
    /// presets nobody chose: they're dropped once, so everyone starts from the small card.
    public static let savedVersion = 2

    /// "small", "medium", or "custom:x,y,w,h"; anything else is the standard small card.
    public init(saved: String?) {
        guard let saved else { self = .standard; return }
        if saved.hasPrefix("custom:") {
            let numbers = saved.dropFirst("custom:".count).split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { self = .standard; return }
            self.init(preset: .custom, frame: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        } else {
            self.init(preset: LyricsPreset(rawValue: saved) ?? .small)
        }
    }

    public var saved: String {
        guard preset == .custom, let frame else { return preset.rawValue }
        return "custom:\(Double(frame.minX)),\(Double(frame.minY)),\(Double(frame.width)),\(Double(frame.height))"
    }
}

/// Where the card sits: centred just under the notch (and the menu bar), or wherever it
/// was dragged.
public enum LyricsPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case underNotch
    case free

    public var id: String { rawValue }
    public var title: String { self == .underNotch ? "Under the notch" : "Where I drag it" }
}

/// The card's frame for a preset, and the limits a drag or a typed size stays within.
public enum LyricsGeometry {
    public static let minimumSize = CGSize(width: 100, height: 44)
    /// The small card: a tenth of the screen's width, tall enough for two or three lines.
    public static let smallWidthFraction: CGFloat = 0.10
    public static let smallHeight: CGFloat = 68
    public static let mediumWidthFraction: CGFloat = 0.25
    public static let mediumHeight: CGFloat = 128
    public static let bandHeight: CGFloat = 160
    /// Room between the menu bar (or the notch) and the card.
    public static let gap: CGFloat = 6

    /// The room it may take: the whole screen above the Dock, menu bar included (it can be
    /// dragged there, but no preset goes there).
    public static func bounds(screen: CGRect, visible: CGRect) -> CGRect {
        let bottom = max(screen.minY, min(visible.minY, screen.maxY - minimumSize.height))
        return CGRect(x: screen.minX, y: bottom, width: screen.width, height: screen.maxY - bottom)
    }

    /// The size of a preset on a screen.
    public static func size(of preset: LyricsPreset, screen: CGRect, visible: CGRect) -> CGSize {
        switch preset {
        case .small, .custom: return CGSize(width: (screen.width * smallWidthFraction).rounded(), height: smallHeight)
        case .medium: return CGSize(width: (screen.width * mediumWidthFraction).rounded(), height: mediumHeight)
        case .band: return CGSize(width: visible.width - 2 * gap, height: bandHeight)
        case .fullScreen: return CGSize(width: visible.width, height: visible.height)
        }
    }

    /// The frame in global coordinates. Under the notch, the card is centred on the camera
    /// (or the screen) just below the menu bar, whatever its size; free, a dragged card keeps
    /// its place.
    public static func frame(for placement: LyricsPlacement, position: LyricsPosition,
                             screen: CGRect, visible: CGRect, notch: CGRect?) -> CGRect {
        let bounds = bounds(screen: screen, visible: visible)
        let size = placement.frame?.size ?? self.size(of: placement.preset, screen: screen, visible: visible)
        if position == .free, let saved = placement.frame {
            return clamp(saved.offsetBy(dx: screen.minX, dy: screen.minY), to: bounds)
        }
        if placement.preset == .fullScreen { return clamp(visible, to: bounds) }
        return clamp(underNotch(size, screen: screen, visible: visible, notch: notch), to: bounds)
    }

    /// `size` centred under the camera, just below the menu bar.
    public static func underNotch(_ size: CGSize, screen: CGRect, visible: CGRect, notch: CGRect?) -> CGRect {
        let centre = notch?.midX ?? screen.midX
        let top = min(visible.maxY, notch?.minY ?? visible.maxY) - gap
        return CGRect(x: centre - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    /// `rect` at least the minimum size and at most `bounds`, moved (not shrunk further) to
    /// lie inside it.
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumSize.width), bounds.width)
        let height = min(max(rect.height, minimumSize.height), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        // Whole points, without growing (`integral` would add a point to a half-point origin).
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Which edges a drag moves.
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let bottom = Edges(rawValue: 4)
        public static let top = Edges(rawValue: 8)
    }

    /// The edges under a point `inset` points or less from the card's sides, in its own
    /// coordinates (origin bottom-left). Corners take a wider band, but never more than a
    /// third of a small card.
    public static func edges(at point: CGPoint, in size: CGSize, inset: CGFloat = 6) -> Edges {
        var edges: Edges = []
        if point.x <= inset { edges.insert(.left) } else if point.x >= size.width - inset { edges.insert(.right) }
        if point.y <= inset { edges.insert(.bottom) } else if point.y >= size.height - inset { edges.insert(.top) }
        let cornerX = min(inset * 3, size.width / 3)
        let cornerY = min(inset * 3, size.height / 3)
        if edges.contains(.left) || edges.contains(.right) {
            if point.y <= cornerY { edges.insert(.bottom) } else if point.y >= size.height - cornerY { edges.insert(.top) }
        }
        if edges.contains(.bottom) || edges.contains(.top) {
            if point.x <= cornerX { edges.insert(.left) } else if point.x >= size.width - cornerX { edges.insert(.right) }
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

    /// The card at a typed size: the same top edge and centre, inside `bounds`.
    public static func sized(_ rect: CGRect, width: CGFloat, height: CGFloat, within bounds: CGRect) -> CGRect {
        let next = CGRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height)
        return clamp(next, to: bounds)
    }
}

/// Where the card's tuning panel goes: under the card, its right edges lined up, else above it
/// when there's no room below, always on the screen.
public enum LyricsTuning {
    public static let size = CGSize(width: 290, height: 520)
    public static let gap: CGFloat = 6

    public static func frame(size: CGSize = size, card: CGRect, within bounds: CGRect) -> CGRect {
        var frame = CGRect(x: card.maxX - size.width, y: card.minY - gap - size.height, width: size.width, height: size.height)
        if frame.minY < bounds.minY { frame.origin.y = card.maxY + gap }
        if frame.maxY > bounds.maxY {
            // No room above or below: beside the card, on whichever side has room.
            frame.origin.y = bounds.maxY - size.height
            frame.origin.x = card.minX - gap - size.width >= bounds.minX ? card.minX - gap - size.width : card.maxX + gap
        }
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - size.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - size.height)
        return frame
    }
}

/// Where the hover buttons (× and the tuning button) go: the card's top-right corner, unless the
/// camera would hide them there; then its bottom-right.
public enum LyricsControls {
    public static let size = CGSize(width: 54, height: 24)
    public static let inset: CGFloat = 5

    /// True for the top corner. `panel` and `notch` in global coordinates.
    public static func atTop(panel: CGRect, notch: CGRect?) -> Bool {
        guard let notch else { return true }
        let corner = CGRect(x: panel.maxX - size.width - inset, y: panel.maxY - size.height - inset,
                            width: size.width, height: size.height)
        return !corner.intersects(notch)
    }
}

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

/// How big the words are and how many lines show, from the card's size and the person's
/// choices.
public enum LyricsTypography {
    public static let headerHeight: CGFloat = 44
    public static let scaleRange: ClosedRange<Double> = 0.5...2.5
    /// The smallest words worth showing; below it, fewer lines show instead.
    public static let smallest: CGFloat = 10
    /// Each line takes this many times its font size, with the space between lines.
    public static let lineHeight: CGFloat = 1.4

    /// Only a card this big has room for the track's name and artwork above the words; a
    /// smaller one shows its buttons on hover instead.
    public static func showsHeader(panel: CGSize) -> Bool {
        panel.width >= 320 && panel.height >= 180
    }

    /// The vertical padding around the words.
    public static func padding(panel: CGSize) -> CGFloat {
        min(max(panel.height * 0.08, 5), 18)
    }

    public struct Layout: Equatable, Sendable {
        public var fontSize: CGFloat
        /// How many lines show around the current one; nil: every line, scrolling.
        public var lines: Int?
    }

    /// The words' size and the number of lines for a card. With a line count, the words
    /// grow to fill the card (up to its width allowing), and lines are dropped while the words
    /// would be too small to read; with every line, they're sized to show about six.
    public static func layout(panel: CGSize, lines requested: LyricsLineCount, scale: Double) -> Layout {
        let header = showsHeader(panel: panel) ? headerHeight : 0
        let room = max(0, panel.height - header - 2 * padding(panel: panel))
        let scale = CGFloat(min(max(scale.isFinite ? scale : 1, scaleRange.lowerBound), scaleRange.upperBound))
        let widest = max(smallest, panel.width * 0.085)
        guard var count = requested.count else {
            let size = min(max(min(room / (6 * lineHeight), widest), 14), 56)
            return Layout(fontSize: (size * scale).rounded(), lines: nil)
        }
        func size(for count: Int) -> CGFloat { min(room / (CGFloat(count) * lineHeight), widest, 64) * scale }
        while count > 1, size(for: count) < smallest { count -= 1 }
        return Layout(fontSize: max(smallest * min(scale, 1), size(for: count)).rounded(), lines: count)
    }

    /// Where the current line sits in a scrolling list, from the top (0) to the bottom (1).
    public static func anchor(height: CGFloat) -> CGFloat {
        height < 240 ? 0.08 : 0.33
    }
}

/// How many lines show at once.
public enum LyricsLineCount: String, Codable, CaseIterable, Identifiable, Sendable {
    case one, two, three, five, all

    public var id: String { rawValue }
    public var count: Int? {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .five: return 5
        case .all: return nil
        }
    }
    public var title: String { count.map(String.init) ?? "All" }

    /// The lines to show around `current` (nil before the first line): just it and what comes
    /// next for one or two lines, centred on it for more, kept inside the song.
    public static func window(count: Int, around current: Int?, total: Int) -> Range<Int> {
        guard total > 0, count > 0 else { return 0..<0 }
        let count = min(count, total)
        let before = count >= 3 ? (count - 1) / 2 : 0
        let start = min(max((current ?? 0) - before, 0), total - count)
        return start..<(start + count)
    }
}

public enum LyricsOffset {
    public static let step: Double = 0.1
    public static let range: ClosedRange<Double> = -3...3

    /// `value` moved by `steps` tenths of a second, rounded to a tenth, within ±3 s.
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
public enum LyricsAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        }
    }
}
