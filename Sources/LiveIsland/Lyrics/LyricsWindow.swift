import AppKit
import Combine
import LiveIslandCore
import os
import SwiftUI

private let log = Logger(subsystem: "com.aissam.liveisland", category: "lyrics")

/// The display Sing With Me opens on: the island's.
struct LyricsScreen: Equatable {
    var id: String
    var frame: CGRect
    var visible: CGRect
    /// The camera housing, in global coordinates; nil without one.
    var notch: CGRect?

    var bounds: CGRect { LyricsGeometry.bounds(screen: frame, visible: visible) }

    func frame(for placement: LyricsPlacement, position: LyricsPosition) -> CGRect {
        LyricsGeometry.frame(for: placement, position: position, screen: frame, visible: visible, notch: notch)
    }

    /// A frame relative to this display, as placements keep it.
    func relative(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }

    /// The same pick as the island's: the display chosen in Settings, else the one with the
    /// notch, else the menu bar's.
    static func current(for choice: DisplayChoice) -> LyricsScreen? {
        let screens = NSScreen.screens
        let ids = screens.enumerated().map { index, screen in screen.displayUUID ?? "screen-\(index)" }
        let displays = zip(screens, ids).enumerated().map { index, pair in
            DisplayChoice.Display(id: pair.1, hasNotch: pair.0.hasNotch, isPrimary: index == 0)
        }
        guard let index = choice.pick(from: displays) else { return nil }
        let screen = screens[index]
        var notch: CGRect?
        if screen.hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                           width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        }
        return LyricsScreen(id: ids[index], frame: screen.frame, visible: screen.visibleFrame, notch: notch)
    }
}

/// What the lyrics view needs from the window: its frame (for the size of the words and
/// where the buttons go), whether the pointer is on it, and whether details are hidden.
@MainActor
final class LyricsWindowState: ObservableObject {
    @Published var frame: CGRect = .zero
    @Published var screen: LyricsScreen?
    @Published var hidesDetails = false
    @Published var isHovering = false
    /// The tuning panel is open: the card's buttons stay visible.
    @Published var isTuning = false
    /// The icon button under the pointer, for their shared hover look.
    @Published private(set) var hoveredButton: String?

    func setHovered(_ id: String, _ inside: Bool) {
        if inside, hoveredButton != id { hoveredButton = id } else if !inside, hoveredButton == id { hoveredButton = nil }
    }

    var header: LyricsHeaderLayout { LyricsHeaderLayout(panel: frame, notch: screen?.notch) }
    var controlsAtTop: Bool { LyricsControls.atTop(panel: frame, notch: screen?.notch) }
}

/// A borderless panel that never takes focus: typing still goes to the app in front.
final class LyricsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // Just under the island, which stays on top of it.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The SwiftUI host, acting on the first click like the island's.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content: the SwiftUI card, with every edge and corner a handle to resize it.
/// On macOS 26 the card draws its own Liquid Glass; before it, a frosted backdrop (an
/// `NSVisualEffectView`, the only real blur of what's behind a window) sits under it,
/// rounded like the card.
final class LyricsResizingView: NSView {
    var limits: (() -> CGRect)?
    var onFrame: ((CGRect, Bool) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Only before macOS 26.
    private let backdrop: NSVisualEffectView?
    private let host: NSView
    private var drag: (start: CGRect, mouse: CGPoint, edges: LyricsGeometry.Edges)?
    private var look = LyricsAppearance.standard
    private var maskedRadius: CGFloat?
    private static let inset: CGFloat = 6

    init(host: NSView) {
        self.host = host
        backdrop = LiquidGlass.isAvailable ? nil : NSVisualEffectView()
        super.init(frame: .zero)
        if let backdrop {
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.material = .hudWindow
            backdrop.autoresizingMask = [.width, .height]
            addSubview(backdrop)
        }
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
        host.frame = bounds
        updateMask()
    }

    /// The fallback's look: frosted or lighter for clear glass, dark or light.
    func apply(_ look: LyricsAppearance) {
        self.look = look
        guard let backdrop else { return }
        backdrop.alphaValue = look.glass == .regular ? 1 : 0.45
        backdrop.appearance = NSAppearance(named: look.hasLightBackground ? .aqua : .darkAqua)
        updateMask()
    }

    /// The fallback's corners: a small nine-part image, its middle stretched, so it fills the
    /// whole card at any size.
    private func updateMask() {
        guard let backdrop else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let radius = min(CGFloat(look.cornerRadius), min(size.width, size.height) / 2).rounded()
        if maskedRadius == radius, backdrop.maskImage != nil { return }
        maskedRadius = radius
        let cap = radius + 1
        let side = cap * 2 + 1
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        backdrop.maskImage = image
    }

    private func edges(at point: CGPoint) -> LyricsGeometry.Edges {
        LyricsGeometry.edges(at: point, in: bounds.size, inset: Self.inset)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return edges(at: local).isEmpty ? super.hitTest(point) : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        if edges.isEmpty { NSCursor.arrow.set() } else { Self.cursor(for: edges).set() }
    }

    override func mouseExited(with event: NSEvent) {
        if drag == nil { NSCursor.arrow.set() }
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty else { return }
        drag = (window.frame, NSEvent.mouseLocation, edges)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let bounds = limits?() else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGSize(width: mouse.x - drag.mouse.x, height: mouse.y - drag.mouse.y)
        onFrame?(LyricsGeometry.resize(drag.start, edges: drag.edges, by: delta, within: bounds), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil, let window else { return }
        drag = nil
        onFrame?(window.frame, true)
    }

    static func cursor(for edges: LyricsGeometry.Edges) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch (edges.contains(.left), edges.contains(.right), edges.contains(.top), edges.contains(.bottom)) {
            case (true, _, true, _): position = .topLeft
            case (true, _, _, true): position = .bottomLeft
            case (_, true, true, _): position = .topRight
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        if horizontal && vertical { return .crosshair }
        return horizontal ? .resizeLeftRight : .resizeUpDown
    }
}

/// Owns the Sing With Me card: shows it on the island's display at the size saved for that
/// display (small, under the notch, unless the person chose otherwise) while it's open and
/// the song has words, follows drags and resizes, opens its tuning panel, and listens for
/// Escape only while it's on screen.
@MainActor
final class LyricsWindowController {
    private let model: IslandModel
    private var sing: SingWithMe { model.singWithMe }
    private let state = LyricsWindowState()
    private var panel: LyricsPanel?
    private var container: LyricsResizingView?
    private var visibilityChanges: AnyCancellable?
    /// On screen now. Open with a song without words, the card is hidden, not closed.
    private var shown = false
    private var tuning: LyricsPanel?
    private var tuningMonitors: [Any] = []
    /// Only while open: placements, the look, privacy, displays, keys.
    private var whileOpen: [AnyCancellable] = []
    private var monitors: [Any] = []
    private var screenObservers: [NSObjectProtocol] = []
    private var moveStart: (frame: CGRect, mouse: CGPoint)?
    private static let escape: UInt16 = 53
    /// While Sing With Me is off, the card opens big enough to explain itself.
    private static let optInSize = CGSize(width: 380, height: 210)

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        // `@Published` sends before the value changes: look on the next turn of the main queue.
        let changes = Publishers.Merge3(sing.$isOpen.map { _ in () }, sing.$state.map { _ in () }, sing.$isEnabled.map { _ in () })
        visibilityChanges = changes.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
    }

    private func updateVisibility() {
        let visible = LyricsVisibility.showsCard(isOpen: sing.isOpen, isEnabled: sing.isEnabled, lyrics: sing.lyrics)
        guard visible != shown else { return }
        if visible { show() } else { hide() }
    }

    /// Where the card belongs now: the explanation's size while off, else the saved placement.
    private func targetFrame(on screen: LyricsScreen) -> CGRect {
        if !sing.isEnabled {
            return LyricsGeometry.clamp(LyricsGeometry.underNotch(Self.optInSize, screen: screen.frame, visible: screen.visible,
                                                                  notch: screen.notch), to: screen.bounds)
        }
        return screen.frame(for: sing.placement(for: screen.id), position: sing.appearance.position)
    }

    private func show() {
        guard let screen = LyricsScreen.current(for: model.islandDisplay) else { sing.close(); return }
        shown = true
        let panel = self.panel ?? makePanel()
        state.screen = screen
        state.hidesDetails = model.hidesDetails
        state.isHovering = false
        setFrame(targetFrame(on: screen), save: false)
        applyLook()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.25
            panel.animator().alphaValue = 1
        }
        watchWhileOpen()
        log.notice("Sing With Me card: \(Int(panel.frame.width), privacy: .public)×\(Int(panel.frame.height), privacy: .public)")
    }

    private func hide() {
        shown = false
        closeTuning()
        stopWatching()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                panel.orderOut(nil)
                // Nothing stays behind: the view and its observers go with the window.
                panel.contentView = nil
                self.panel = nil
                self.container = nil
            }
        })
    }

    private func makePanel() -> LyricsPanel {
        let panel = LyricsPanel()
        let view = LyricsView(sing: sing, window: state, model: model, actions: LyricsActions(
            close: { [weak self] in self?.sing.close() },
            choose: { [weak self] in self?.choose($0) },
            tune: { [weak self] in self?.toggleTuning() },
            beginMove: { [weak self] in self?.beginMove() },
            move: { [weak self] in self?.move() },
            endMove: { [weak self] in self?.endMove() }))
        let host = FirstClickHostingView(rootView: view)
        let container = LyricsResizingView(host: host)
        container.limits = { [weak self] in self?.state.screen?.bounds ?? .zero }
        container.onFrame = { [weak self] frame, done in self?.setFrame(frame, save: done) }
        container.onHover = { [weak self] hovering in
            guard let self, self.state.isHovering != hovering else { return }
            self.state.isHovering = hovering
        }
        panel.contentView = container
        self.panel = panel
        self.container = container
        return panel
    }

    /// Sets the card's frame; at the end of a drag, saves it as the custom size (and place,
    /// once it's been moved).
    private func setFrame(_ frame: CGRect, save: Bool) {
        guard let panel else { return }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if state.frame != frame { state.frame = frame }
        placeTuning()
        guard save, sing.isEnabled, let screen = state.screen else { return }
        sing.setPlacement(LyricsPlacement(preset: .custom, frame: screen.relative(frame)), for: screen.id)
        // Resized under the notch, it stays centred there.
        if sing.appearance.position == .underNotch {
            let centred = targetFrame(on: screen)
            if centred != frame { animate(to: centred) }
        }
    }

    private func choose(_ preset: LyricsPreset) {
        guard let screen = state.screen, preset != .custom else { return }
        sing.appearance.position = .underNotch
        sing.setPlacement(LyricsPlacement(preset: preset), for: screen.id)
        animate(to: targetFrame(on: screen))
    }

    private func animate(to frame: CGRect) {
        guard let panel else { return }
        state.frame = frame
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
        panel.invalidateShadow()
    }

    private func applyLook() {
        let look = sing.appearance
        container?.apply(look)
        // Liquid Glass has its own depth; the fallback's frosted card gets the window's shadow.
        panel?.hasShadow = !LiquidGlass.isAvailable
        panel?.invalidateShadow()
    }

    // MARK: - Tuning

    /// The card's own settings, live: a small panel attached to it. Its sliders and chips
    /// are SwiftUI drags and buttons, which act on the first click, so it never needs to
    /// take the keyboard either.
    private func toggleTuning() {
        if tuning != nil { closeTuning(); return }
        guard let panel else { return }
        let tuning = LyricsPanel()
        tuning.hasShadow = true
        let view = LyricsTuningView(sing: sing, window: state, actions: LyricsTuningActions(
            choose: { [weak self] in self?.choose($0) },
            settings: { [weak self] in
                self?.closeTuning()
                self?.model.openSettings(.media, anchor: "lyrics")
            },
            close: { [weak self] in self?.closeTuning() }))
        tuning.contentView = FirstClickHostingView(rootView: view)
        self.tuning = tuning
        placeTuning()
        panel.addChildWindow(tuning, ordered: .above)
        tuning.orderFrontRegardless()
        state.isTuning = true
        // A click anywhere but the card or the panel puts it away.
        let click: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tuning = self.tuning, let card = self.panel else { return }
                let point = NSEvent.mouseLocation
                if !tuning.frame.contains(point), !card.frame.contains(point) { self.closeTuning() }
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click) {
            tuningMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            click(event)
            return event
        }) { tuningMonitors.append(monitor) }
    }

    private func placeTuning() {
        guard let tuning, let bounds = state.screen?.bounds else { return }
        tuning.setFrame(LyricsTuning.frame(card: state.frame, within: bounds), display: true)
    }

    private func closeTuning() {
        tuningMonitors.forEach(NSEvent.removeMonitor)
        tuningMonitors = []
        guard let tuning else { return }
        panel?.removeChildWindow(tuning)
        tuning.orderOut(nil)
        tuning.contentView = nil
        self.tuning = nil
        state.isTuning = false
    }

    // MARK: - Moving it by dragging

    private func beginMove() {
        guard let panel, moveStart == nil else { return }
        moveStart = (panel.frame, NSEvent.mouseLocation)
    }

    private func move() {
        if moveStart == nil { beginMove() }
        guard let start = moveStart, let bounds = state.screen?.bounds else { return }
        let mouse = NSEvent.mouseLocation
        let moved = start.frame.offsetBy(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y)
        let clamped = LyricsGeometry.clamp(moved, to: bounds)
        guard let panel, panel.frame != clamped else { return }
        panel.setFrameOrigin(clamped.origin)
        state.frame = clamped
    }

    /// Set down somewhere: it stays there ("where I drag it"); a click that didn't move it
    /// changes nothing.
    private func endMove() {
        guard let start = moveStart, let panel else { return }
        moveStart = nil
        guard panel.frame != start.frame, sing.isEnabled, let screen = state.screen else { return }
        sing.appearance.position = .free
        sing.setPlacement(LyricsPlacement(preset: .custom, frame: screen.relative(panel.frame)), for: screen.id)
    }

    // MARK: - While open

    private func watchWhileOpen() {
        stopWatching()
        // Settings typed a size, picked a preset or a position, or Sing With Me was turned on.
        let placementChanges = Publishers.Merge3(sing.$placements.dropFirst().map { _ in () },
                                                 sing.$appearance.dropFirst().map(\.position).removeDuplicates().map { _ in () },
                                                 sing.$isEnabled.dropFirst().map { _ in () })
        whileOpen.append(placementChanges.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = self.state.screen, self.moveStart == nil else { return }
                let target = self.targetFrame(on: screen)
                if target != self.state.frame { self.animate(to: target) }
            }
        })
        whileOpen.append(sing.$appearance.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLook() }
        })
        whileOpen.append(Publishers.CombineLatest3(model.$alwaysHideDetails, model.$hideDetailsWhileSharing, model.$screenShared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state.hidesDetails != self.model.hidesDetails else { return }
                    self.state.hidesDetails = self.model.hidesDetails
                }
            })
        whileOpen.append(model.$islandDisplay.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        screenObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        // Escape puts the tuning panel away, else closes the card: in other apps when
        // LiveIsland may watch keys, and always in its own windows. Neither panel takes the
        // keyboard.
        let key: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == Self.escape else { return false }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.tuning != nil { self.closeTuning() } else { self.sing.close() }
            }
            return true
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = key($0) }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0) ? nil : $0 }) { monitors.append(monitor) }
    }

    private func stopWatching() {
        whileOpen.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        screenObservers.forEach(NotificationCenter.default.removeObserver)
        screenObservers = []
        moveStart = nil
    }

    private func screensChanged() {
        guard sing.isOpen, let screen = LyricsScreen.current(for: model.islandDisplay) else { return }
        state.screen = screen
        setFrame(targetFrame(on: screen), save: false)
    }
}
