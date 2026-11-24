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

    /// Idle at the top edge of a display without a notch, the island draws nothing: it must not
    /// catch clicks there, and opens only from `TopEdgeHotSpot`.
    func drawsNothing(expanded: Bool, active: Bool) -> Bool {
        !expanded && !active && !hasNotch && !isFloating
    }

    /// How far the island's centre sits from the window's, so it can slide clear of a screen edge.
    func horizontalOffset(expanded: Bool, active: Bool) -> CGFloat {
        islandFrame(expanded: expanded, active: active).midX - windowFrame.midX
    }
}

/// A borderless panel above the menu bar that never takes focus away from the user's app.
final class IslandPanel: NSPanel {
    /// Only while the island is being placed may it take the keyboard; otherwise typing after
    /// a click on play/pause would land here instead of in the app in front.
    var acceptsKeyboard = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
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

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// The island's SwiftUI host. A panel that never becomes key still has to act on the first
/// click, or every button would need two.
private final class IslandHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel: places it on the chosen display, follows display changes, and makes it
/// respond to the mouse only where the island is.
@MainActor
final class IslandController {
    private let model: IslandModel
    private let panel = IslandPanel()
    private let watcher = ScreenContentWatcher()
    private var layout: IslandLayout?
    /// The display the island is on, to tell whether an app is full screen there.
    private var screen: NSScreen?
    private var host: IslandHostingView?
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var placementChanges: AnyCancellable?
    private var moving: AnyCancellable?
    private var modelChanges: AnyCancellable?
    private var refreshQueued = false
    private var wasExpanded = false
    /// The two screen settings as last looked at, to look again when one is turned on.
    private var screenSettings = (fullScreen: false, sharing: false)
    private var follow: Following?
    private var dismissal: Dismissal?
    /// An app is full screen on the island's display (checked only while the setting is on).
    private var overFullScreen = false
    /// Hidden over a full-screen app.
    private var hidden = false
    /// Set down this close to the top centre of a display, the island goes back to the top edge.
    private static let dockDistance: CGFloat = 60
    /// Opened by a link or a menu, the island closes this long after opening if the pointer never comes.
    private static let unattendedTimeout: TimeInterval = 6
    /// Placing gives up when the pointer hasn't moved for this long.
    private static let placingTimeout: TimeInterval = 30
    private static let escape: CGKeyCode = 53
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
        // The island grows, shrinks or changes under a still pointer too: click-through, the
        // close-on-click watch and hiding over full screen follow every change, not only moves.
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        }
        watcher.onChange = { [weak self] in self?.screensChanged() }
        watcher.start()
        screensChanged()
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
        screen = screens[index]
        apply(IslandLayout(screen: screens[index], placement: model.islandPlacement))
        checkFullScreen()
    }

    private func apply(_ next: IslandLayout) {
        guard next != layout else { return }
        layout = next
        let view = AnyView(IslandView(layout: next).environmentObject(model))
        if let host {
            host.rootView = view
        } else {
            let host = IslandHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: IslandLayout.canvas)
            panel.contentView = host
            self.host = host
        }
        panel.setFrame(next.windowFrame, display: true)
    }

    // MARK: - Following the model

    /// Many settings change at once (a snapshot, a tab): look once, on the next turn of the main
    /// queue, after they're all set.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                self.modelChanged()
            }
        }
    }

    private func modelChanged() {
        if model.isExpanded != wasExpanded {
            wasExpanded = model.isExpanded
            if model.isExpanded { watchForDismissal() } else { stopWatchingForDismissal() }
        }
        if (model.hideOverFullScreen, model.hideDetailsWhileSharing) != screenSettings {
            screensChanged()
        }
        if follow == nil { trackMouse() }
        updateVisibility()
    }

    // MARK: - Closing an island nobody is pointing at

    /// While open: a click anywhere else, or Escape, closes it. Opened by a link or a menu (the
    /// pointer isn't on it), it also closes by itself if the pointer never comes; once it has,
    /// leaving closes it as usual.
    private struct Dismissal {
        var monitors: [Any]
        var timeout: Timer?
        var escapePoll: Timer?
    }

    private func watchForDismissal() {
        stopWatchingForDismissal()
        var watch = Dismissal(monitors: [])
        let click: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps reach a global monitor without any permission.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: click) { watch.monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { event in
            click(event)
            return event
        }) { watch.monitors.append(monitor) }
        // Escape: in LiveIsland's own windows always, in other apps when it may watch keys.
        let key: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == Self.escape else { return }
            MainActor.assumeIsolated { self?.model.collapse() }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { watch.monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            key(event)
            return event
        }) { watch.monitors.append(monitor) }
        if !model.isHovering {
            // The first run's hint gets time to be read.
            let timeout = Timer(timeInterval: model.showsWelcome ? 15 : Self.unattendedTimeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.model.isHovering else { return }
                    self.model.collapse()
                }
            }
            RunLoop.main.add(timeout, forMode: .common)
            watch.timeout = timeout
            // Without that permission, Escape is still seen by looking at the key itself, for
            // the few seconds until the pointer comes or the island closes.
            let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, !self.model.isHovering else { timer.invalidate(); return }
                    if CGEventSource.keyState(.combinedSessionState, key: Self.escape) { self.model.collapse() }
                }
            }
            RunLoop.main.add(poll, forMode: .common)
            watch.escapePoll = poll
        }
        dismissal = watch
    }

    private func stopWatchingForDismissal() {
        guard let watch = dismissal else { return }
        watch.monitors.forEach(NSEvent.removeMonitor)
        watch.timeout?.invalidate()
        watch.escapePoll?.invalidate()
        dismissal = nil
        giveKeyBack()
    }

    private func clicked(at point: CGPoint) {
        guard model.isExpanded, follow == nil, let layout else { return }
        let island = layout.islandFrame(expanded: true, active: model.primary != nil)
        if !island.insetBy(dx: -6, dy: -6).contains(point) { model.collapse() }
    }

    /// The panel never keeps the keyboard: whatever had it before gets it back.
    private func giveKeyBack() {
        if follow == nil { panel.acceptsKeyboard = false }
        guard panel.isKeyWindow else { return }
        panel.resignKey()
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            front.activate()
        }
    }

    // MARK: - Full screen and screen sharing

    private func screensChanged() {
        screenSettings = (model.hideOverFullScreen, model.hideDetailsWhileSharing)
        checkFullScreen()
        // A full-screen app's Space animates in; look again once it's there.
        if model.hideOverFullScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.checkFullScreen() }
            }
        }
        model.setScreenShared(model.hideDetailsWhileSharing && ScreenContentWatcher.isSharing())
    }

    private func checkFullScreen() {
        var covered = false
        if model.hideOverFullScreen, let number = screen?.displayNumber {
            covered = FullScreen.covers(CGDisplayBounds(number), windows: ScreenContentWatcher.windows(), ignoring: getpid())
        }
        if covered != overFullScreen { overFullScreen = covered }
        updateVisibility()
    }

    /// Over a full-screen app (when that's the setting), only a call or a timer shows; an island
    /// opened on purpose shows too.
    private func updateVisibility() {
        let hide = model.hideOverFullScreen && overFullScreen && follow == nil && !model.isExpanded
            && !(model.primary?.showsOverFullScreen ?? false)
        guard hide != hidden else { return }
        hidden = hide
        if hide {
            panel.ignoresMouseEvents = true
            model.setHovering(false)
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            trackMouse()
        }
    }

    // MARK: - Placing

    /// While the island follows the pointer, after a click on the pin.
    private final class Following {
        /// The window's offset from the pointer.
        let offset: CGSize
        let started = Date()
        var tap: CommandTap
        var timer: Timer?
        var monitors: [Any] = []
        var appSwitches: NSObjectProtocol?
        var lastPointer: CGPoint
        var lastMove = Date()

        init(offset: CGSize, commandDown: Bool, pointer: CGPoint) {
            self.offset = offset
            tap = CommandTap(commandDown: commandDown)
            lastPointer = pointer
        }
    }

    /// The modifier keys, by key code; everything else held with ⌘ makes it a shortcut.
    private static let modifierKeys: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// After a click on the pin: the island floats under the pointer and follows it, until a
    /// click on it or ⌘ on its own sets it down, or Escape (or a while without moving) cancels.
    private func startFollowing() {
        guard follow == nil else { return }
        let point = NSEvent.mouseLocation
        Self.log.notice("Move: following from \(point.x, privacy: .public),\(point.y, privacy: .public)")
        guard let screen = Self.screen(at: point) else { model.endMovingIsland(); return }
        apply(IslandLayout(screen: screen, placement: IslandPlacement(center: point, in: screen.frame)))
        guard let layout else { return }
        stopWatchingForDismissal()
        if hidden { hidden = false; panel.orderFrontRegardless() }
        model.setHovering(false)
        let window = layout.windowFrame.origin
        let current = Following(offset: CGSize(width: window.x - layout.notch.midX, height: window.y - layout.notch.midY),
                                commandDown: NSEvent.modifierFlags.contains(.command), pointer: point)
        follow = current
        // The pill stays under the pointer, so a click lands on it, not on what's below.
        panel.ignoresMouseEvents = false
        panel.acceptsKeyboard = true
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkKeys() }
        }
        RunLoop.main.add(timer, forMode: .common)
        current.timer = timer
        let click: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                // Not the click (or the link) that started it.
                guard let self, let follow = self.follow, Date().timeIntervalSince(follow.started) > 0.3 else { return }
                self.stopFollowing(setDown: true)
            }
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in
            click(event)
            return nil
        }) { current.monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: click) { current.monitors.append(monitor) }
        // Escape cancels: seen by a monitor when LiveIsland is in front (or may watch keys), and
        // by looking at the key otherwise. Other keys with ⌘ make it a shortcut.
        let key: (NSEvent) -> Bool = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let follow = self.follow else { return false }
                if event.keyCode == Self.escape { self.stopFollowing(setDown: false); return true }
                if event.modifierFlags.contains(.command) { follow.tap.noteShortcut() }
                return false
            }
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            key(event) ? nil : event
        }) { current.monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = key($0) }) { current.monitors.append(monitor) }
        // ⌘-Tab brings another app to the front: that ⌘ was a shortcut.
        current.appSwitches = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow?.tap.noteShortcut() }
        }
        followPointer()
    }

    private func followPointer() {
        guard let follow else { return }
        let point = NSEvent.mouseLocation
        if point != follow.lastPointer {
            follow.lastPointer = point
            follow.lastMove = Date()
        }
        panel.setFrameOrigin(CGPoint(x: point.x + follow.offset.width, y: point.y + follow.offset.height))
    }

    /// Polled while following: ⌘ pressed and let go on its own sets the island down, Escape
    /// cancels, and so does a long while without the pointer moving.
    private func checkKeys() {
        guard let follow else { return }
        followPointer()
        if CGEventSource.keyState(.combinedSessionState, key: Self.escape) { stopFollowing(setDown: false); return }
        if Date().timeIntervalSince(follow.lastMove) > Self.placingTimeout {
            Self.log.notice("Move: gave up, the pointer stayed still")
            stopFollowing(setDown: false)
            return
        }
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        // Only while ⌘ is down is it worth looking at every other key.
        let others = command && (!flags.intersection([.shift, .option, .control]).isEmpty || Self.otherKeyDown())
        if follow.tap.update(commandDown: command, otherKeysDown: others) { stopFollowing(setDown: true) }
    }

    private static func otherKeyDown() -> Bool {
        (0..<128).contains { code in
            let key = CGKeyCode(code)
            return !modifierKeys.contains(key) && CGEventSource.keyState(.combinedSessionState, key: key)
        }
    }

    /// Saves where the island was set down (on whichever display, or back on the top edge when
    /// near its middle), or with `setDown` false puts it back where it was.
    private func stopFollowing(setDown: Bool) {
        guard let current = follow else { return }
        Self.log.notice("Move: \(setDown ? "set down" : "cancelled", privacy: .public)")
        current.timer?.invalidate()
        current.monitors.forEach(NSEvent.removeMonitor)
        if let observer = current.appSwitches { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        follow = nil
        giveKeyBack()
        if setDown, let screen = Self.screen(at: NSEvent.mouseLocation) {
            let point = NSEvent.mouseLocation
            let topMiddle = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
            let docked = hypot(point.x - topMiddle.x, point.y - topMiddle.y) < Self.dockDistance
            model.placeIsland(on: screen.displayUUID, at: docked ? nil : IslandPlacement(center: point, in: screen.frame))
        }
        model.endMovingIsland()
        layout = nil
        place()
        panel.ignoresMouseEvents = true
        trackMouse()
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        return screens.first(where: { $0.frame.contains(point) })
            ?? screens.min(by: { $0.frame.distance(to: point) < $1.frame.distance(to: point) })
    }

    // MARK: - The pointer

    private func trackMouse() {
        guard let layout, follow == nil, !hidden else { return }
        let point = NSEvent.mouseLocation
        // Most moves are nowhere near the notch: skip working out the island's size for those.
        // (A little above the window too: the pointer can sit on the very top edge.)
        guard model.isHovering || layout.windowFrame.insetBy(dx: 0, dy: -2).contains(point) else { return }
        let active = model.primary != nil
        let expanded = model.isExpanded
        let island = layout.islandFrame(expanded: expanded, active: active)
        if layout.drawsNothing(expanded: expanded, active: active) {
            // Nothing is drawn, so clicks on the menu bar's middle stay the menu bar's.
            panel.ignoresMouseEvents = true
            model.setHovering(TopEdgeHotSpot.contains(point, area: island, screenTop: layout.screenTop),
                              dwell: TopEdgeHotSpot.dwell)
            return
        }
        let inside = island.insetBy(dx: -6, dy: -6).contains(point)
        // Outside the island, clicks go straight through to the menu bar and apps below.
        panel.ignoresMouseEvents = !inside
        model.setHovering(inside)
    }
}

/// Tells the island when what's on screen may have changed: another Space (a full-screen app
/// comes and goes there), another app in front, an app launched or quit (a screen recorder).
/// All notifications, nothing polled.
@MainActor
final class ScreenContentWatcher {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    /// The windows on screen now (owners and frames only: their titles need a permission, and
    /// aren't needed).
    static func windows() -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return (list ?? []).compactMap(ScreenWindow.init(info:))
    }

    static func isSharing() -> Bool {
        ScreenSharing.isSharing(windows: windows(),
                                runningApps: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

extension NSScreen {
    var displayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private extension CGRect {
    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}
