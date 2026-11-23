import CoreGraphics
import Foundation

/// Where the person dragged the island, away from the notch: the centre of its idle pill, as a
/// fraction of the display (0…1 from the left, 0…1 from the bottom), so it lands in the same
/// spot when the resolution or arrangement changes.
public struct IslandPlacement: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    /// The pill centred on `point`, a point on `screen`.
    public init(center point: CGPoint, in screen: CGRect) {
        self.init(x: (point.x - screen.minX) / max(screen.width, 1), y: (point.y - screen.minY) / max(screen.height, 1))
    }

    /// The saved form, "x,y"; nil or anything unreadable is "on the notch".
    public init?(saved: String?) {
        let parts = (saved ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy(\.isFinite) else { return nil }
        self.init(x: parts[0], y: parts[1])
    }

    public var saved: String { "\(x),\(y)" }
}

/// The island floating where it was placed: the idle pill, which way it opens, and the window
/// that holds every size it can take. The window never resizes; only where the island sits in
/// it changes, and it slides sideways rather than past a screen edge.
public struct FloatingGeometry: Equatable, Sendable {
    /// The idle pill, kept fully on the screen.
    public let pill: CGRect
    /// Opens downward from the pill's top edge, else upward from its bottom edge.
    public let opensDown: Bool
    /// The fixed window, inside the screen.
    public let window: CGRect

    public init(placement: IslandPlacement, screen: CGRect, pill size: CGSize, canvas: CGSize) {
        let center = CGPoint(x: screen.minX + placement.x * screen.width, y: screen.minY + placement.y * screen.height)
        var pill = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        pill = Self.keep(pill, in: screen)
        // Open toward the side with room for the whole window; prefer downward, like the notch.
        let roomBelow = pill.maxY - screen.minY
        let roomAbove = screen.maxY - pill.minY
        let down = roomBelow >= canvas.height || roomBelow >= roomAbove
        var window = CGRect(x: pill.midX - canvas.width / 2, y: down ? pill.maxY - canvas.height : pill.minY,
                            width: canvas.width, height: canvas.height)
        window = Self.keep(window, in: screen)
        // A screen shorter than the window: the pill still sits on the window's edge it opens from.
        if down { pill.origin.y = min(pill.origin.y, window.maxY - pill.height) } else { pill.origin.y = max(pill.origin.y, window.minY) }
        self.pill = pill
        self.opensDown = down
        self.window = window
    }

    /// The island at `size`: centred on the pill, opening from it, and slid sideways to stay in
    /// the window.
    public func island(size: CGSize) -> CGRect {
        let width = min(size.width, window.width)
        let x = min(max(pill.midX - width / 2, window.minX), window.maxX - width)
        let y = opensDown ? pill.maxY - size.height : pill.minY
        return CGRect(x: x, y: y, width: width, height: size.height)
    }

    /// `rect` moved, not shrunk, to lie inside `bounds` (centred where it can't fit).
    static func keep(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = rect.width > bounds.width ? bounds.midX - rect.width / 2 : min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = rect.height > bounds.height ? bounds.midY - rect.height / 2 : min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }
}
