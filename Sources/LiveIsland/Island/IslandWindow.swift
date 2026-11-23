import AppKit
import Combine
import LiveIslandCore
import os
import SwiftUI

/// A connected display, as the Settings picker shows it.
struct IslandDisplay: Equatable, Identifiable {
    var id: String
    var name: String
    var hasNotch: Bool
}

extension NSScreen {
    /// The display's UUID, which survives restarts and reconnections (its number doesn't).
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil }
}

/// Where the island sits (on the notch, or where the person dragged it) and how big it gets.
struct IslandLayout: Equatable {
    /// The notch, or the idle pill, in global screen coordinates (bottom-left origin).
    var notch: CGRect
    var hasNotch: Bool
    var screenTop: CGFloat
    /// Set when the island floats where it was dragged instead of hanging from the top edge.
    var floating: FloatingGeometry?

    static let wingWidth: CGFloat = 72
    static let expandedSize = CGSize(width: 680, height: 300)
    /// The window is always this big; everything outside the island is transparent and click-through.
    static let canvas = CGSize(width: 760, height: 370)

    init(screen: NSScreen, placement: IslandPlacement? = nil) {
        screenTop = screen.frame.maxY
        if let placement {
            // Away from the notch: a pill as wide as a notch, as tall as the menu bar.
            hasNotch = false
            let pill = CGSize(width: 200, height: NSStatusBar.system.thickness)
            let geometry = FloatingGeometry(placement: placement, screen: screen.frame, pill: pill, canvas: Self.canvas)
            floating = geometry
            notch = geometry.pill
        } else if screen.hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notch = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                           width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else {
            // No notch: a small pill under the top edge, just as tall as the menu bar.
            hasNotch = false
            let height = NSStatusBar.system.thickness
            notch = CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - height, width: 200, height: height)
        }
    }

    var isFloating: Bool { floating != nil }
    /// Which way the island grows when it opens.
    var opensDown: Bool { floating?.opensDown ?? true }
    /// Room the open island's header leaves in the middle: the camera's, on the notch.
    var headerGap: CGFloat { isFloating ? 24 : notch.width }

    func size(expanded: Bool, active: Bool) -> CGSize {
        if expanded {
            return CGSize(width: max(Self.expandedSize.width, notch.width + 440), height: Self.expandedSize.height)
        }
        if active { return CGSize(width: notch.width + 2 * Self.wingWidth, height: notch.height) }
        // Idle: exactly the notch, so it disappears into it. A floating pill stays visible, so it
        // can be found; without a notch at the top edge, nothing at all.
        return hasNotch || isFloating ? notch.size : CGSize(width: notch.width, height: 0)
    }

    /// The window frame: the canvas, centred under the notch, or around the floating pill.
    var windowFrame: CGRect {
        if let floating { return floating.window }
        return CGRect(x: notch.midX - Self.canvas.width / 2, y: screenTop - Self.canvas.height,
                      width: Self.canvas.width, height: Self.canvas.height)
    }

    /// Where the island is on screen, for hover and click-through.
    func islandFrame(expanded: Bool, active: Bool) -> CGRect {
        let size = size(expanded: expanded, active: active)
        if let floating { return floating.island(size: size) }
        // Without a notch, an idle island still answers to the mouse along the top edge.
        let height = max(size.height, hasNotch ? 0 : 6)
        return CGRect(x: notch.midX - size.width / 2, y: screenTop - height, width: size.width, height: height)
    }

    /// How far the island's centre sits from the window's, so it can slide clear of a screen edge.
    func horizontalOffset(expanded: Bool, active: Bool) -> CGFloat {
        islandFrame(expanded: expanded, active: active).midX - windowFrame.midX
    }
}

/// A borderless panel above the menu bar that never takes focus away from the user's app.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel: places it on the chosen display, follows display changes, and makes it
/// respond to the mouse only where the island is.
@MainActor
final class IslandController {
    private let model: IslandModel
    private let panel = IslandPanel()
    private var layout: IslandLayout?
    private var host: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var placementChanges: AnyCancellable?
    private var moving: AnyCancellable?
    /// While the island follows the pointer: the window's offset from the pointer, and the
    /// check for ⌘ (key presses in other apps can't be seen without Accessibility permission,
    /// but the modifier keys' state can).
    private var follow: (offset: CGSize, timer: Timer, commandWasUp: Bool, keys: Any?)?
    /// Set down this close to the top centre of a display, the island goes back to the top edge.
    private static let dockDistance: CGFloat = 60
    private static let log = Logger(subsystem: "com.aissam.liveisland", category: "island")

    init(model: IslandModel) {
        self.model = model
    }

    func show() {
        place()
        panel.orderFrontRegardless()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.follow != nil { self.followPointer() } else { self.trackMouse() }
            }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event)
            return event
        } as Any)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // `@Published` sends before the property changes; hopping to the next turn of the main
        // queue reads both settings after they're set.
        placementChanges = Publishers.Merge(model.$islandDisplay.dropFirst().map { _ in () },
                                            model.$islandPlacement.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.place() } }
        moving = model.$isMovingIsland.dropFirst().removeDuplicates().filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.startFollowing() } }
    }

    /// Puts the island on the display picked in Settings, or on the one with the notch (else the
    /// menu bar's), and tells Settings which displays there are.
    private func place() {
        let screens = NSScreen.screens
        let ids = screens.enumerated().map { index, screen in screen.displayUUID ?? "screen-\(index)" }
        model.setDisplays(zip(screens, ids).map { IslandDisplay(id: $1, name: $0.localizedName, hasNotch: $0.hasNotch) })
        let displays = zip(screens, ids).enumerated().map { index, pair in
            DisplayChoice.Display(id: pair.1, hasNotch: pair.0.hasNotch, isPrimary: index == 0)
        }
        guard follow == nil, let index = model.islandDisplay.pick(from: displays) else { return }
        apply(IslandLayout(screen: screens[index], placement: model.islandPlacement))
    }

    private func apply(_ next: IslandLayout) {
        guard next != layout else { return }
        layout = next
        let view = AnyView(IslandView(layout: next).environmentObject(model))
        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: IslandLayout.canvas)
            panel.contentView = host
            self.host = host
        }
        panel.setFrame(next.windowFrame, display: true)
    }

    /// After a click on the pin: the island floats under the pointer and follows it.
    private func startFollowing() {
        guard follow == nil else { return }
        let point = NSEvent.mouseLocation
        Self.log.notice("Move: following from \(point.x, privacy: .public),\(point.y, privacy: .public)")
        guard let screen = Self.screen(at: point) else { model.endMovingIsland(); return }
        apply(IslandLayout(screen: screen, placement: IslandPlacement(center: point, in: screen.frame)))
        guard let layout else { return }
        // Clicks go through while it follows, so nothing is pressed by accident.
        panel.ignoresMouseEvents = true
        model.setHovering(false)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCommand() }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Escape cancels, when the island has the keyboard (just after the pin was clicked).
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.stopFollowing(setDown: false) }
            return nil
        }
        let window = layout.windowFrame.origin
        follow = (CGSize(width: window.x - layout.notch.midX, height: window.y - layout.notch.midY), timer,
                  !NSEvent.modifierFlags.contains(.command), keys)
        followPointer()
    }

    private func followPointer() {
        guard let follow else { return }
        let point = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: point.x + follow.offset.width, y: point.y + follow.offset.height))
    }

    /// ⌘ sets it down. If ⌘ was already held when moving began, it has to be let go first.
    private func checkCommand() {
        guard follow != nil else { return }
        followPointer()
        let down = NSEvent.modifierFlags.contains(.command)
        if !down { follow?.commandWasUp = true } else if follow?.commandWasUp == true { stopFollowing(setDown: true) }
    }

    /// Saves where the island was set down (on whichever display, or back on the top edge when
    /// near its middle), or with `setDown` false puts it back where it was.
    private func stopFollowing(setDown: Bool) {
        guard let current = follow else { return }
        Self.log.notice("Move: \(setDown ? "set down" : "cancelled", privacy: .public)")
        current.timer.invalidate()
        if let keys = current.keys { NSEvent.removeMonitor(keys) }
        follow = nil
        if setDown, let screen = Self.screen(at: NSEvent.mouseLocation) {
            let point = NSEvent.mouseLocation
            let topMiddle = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
            let docked = hypot(point.x - topMiddle.x, point.y - topMiddle.y) < Self.dockDistance
            model.placeIsland(on: screen.displayUUID, at: docked ? nil : IslandPlacement(center: point, in: screen.frame))
        }
        model.endMovingIsland()
        layout = nil
        place()
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        return screens.first(where: { $0.frame.contains(point) })
            ?? screens.min(by: { $0.frame.distance(to: point) < $1.frame.distance(to: point) })
    }

    private func trackMouse() {
        guard let layout, follow == nil else { return }
        let point = NSEvent.mouseLocation
        // Most moves are nowhere near the notch: skip working out the island's size for those.
        guard model.isHovering || layout.windowFrame.contains(point) else { return }
        let active = model.primary != nil
        let inside = layout.islandFrame(expanded: model.isExpanded, active: active).insetBy(dx: -6, dy: -6).contains(point)
        // Outside the island, clicks go straight through to the menu bar and apps below.
        panel.ignoresMouseEvents = !inside
        model.setHovering(inside)
    }
}

private extension CGRect {
    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}
