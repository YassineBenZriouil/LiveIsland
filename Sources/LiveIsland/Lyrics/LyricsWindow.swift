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

    func frame(for placement: LyricsPlacement) -> CGRect {
        LyricsGeometry.frame(for: placement, screen: frame, visible: visible, notch: notch)
    }

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

/// What the lyrics view needs from the window: its frame (for the size of the words and where
/// the header goes) and whether details are hidden.
@MainActor
final class LyricsWindowState: ObservableObject {
    @Published var frame: CGRect = .zero
    @Published var screen: LyricsScreen?
    @Published var hidesDetails = false

    var header: LyricsHeaderLayout { LyricsHeaderLayout(panel: frame, notch: screen?.notch) }
    /// Hanging from the top edge, it has no top corners: it grows out of the notch.
    var hangsFromTop: Bool { frame.maxY >= (screen?.frame.maxY ?? .greatestFiniteMagnitude) - 1 }
    var preset: LyricsPreset {
        guard let screen else { return .band }
        let frames = LyricsPreset.allCases.filter { $0 != .custom }.map { ($0, screen.frame(for: LyricsPlacement(preset: $0))) }
        return frames.first(where: { $0.1 == frame })?.0 ?? .custom
    }
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

/// The panel's content: the lyrics, with every edge and corner a handle to resize it.
final class LyricsResizingView: NSView {
    var bounds_: (() -> CGRect)?
    var onFrame: ((CGRect, Bool) -> Void)?
    private let host: NSView
    private var drag: (start: CGRect, mouse: CGPoint, edges: LyricsGeometry.Edges)?
    private static let inset: CGFloat = 6

    init(host: NSView) {
        self.host = host
        super.init(frame: .zero)
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

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        if edges.isEmpty { NSCursor.arrow.set() } else { Self.cursor(for: edges).set() }
    }

    override func mouseExited(with event: NSEvent) {
        if drag == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty else { return }
        drag = (window.frame, NSEvent.mouseLocation, edges)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let limits = bounds_?() else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGSize(width: mouse.x - drag.mouse.x, height: mouse.y - drag.mouse.y)
        onFrame?(LyricsGeometry.resize(drag.start, edges: drag.edges, by: delta, within: limits), false)
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

/// Owns the Sing With Me window: opens it on the island's display at the size saved for that
/// display, follows drags and resizes, and listens for Escape only while it's open.
@MainActor
final class LyricsWindowController {
    private let model: IslandModel
    private var sing: SingWithMe { model.singWithMe }
    private let state = LyricsWindowState()
    private var panel: LyricsPanel?
    private var openChanges: AnyCancellable?
    /// Only while open: placements, privacy, displays, keys.
    private var whileOpen: [AnyCancellable] = []
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var moveStart: (frame: CGRect, mouse: CGPoint)?
    private static let escape: UInt16 = 53

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        openChanges = sing.$isOpen.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in
                MainActor.assumeIsolated { open ? self?.show() : self?.hide() }
            }
    }

    private func show() {
        guard let screen = LyricsScreen.current(for: model.islandDisplay) else { sing.close(); return }
        let panel = self.panel ?? makePanel()
        state.screen = screen
        state.hidesDetails = model.hidesDetails
        setFrame(screen.frame(for: sing.placement(for: screen.id)), save: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.25
            panel.animator().alphaValue = 1
        }
        watchWhileOpen()
        log.notice("Sing With Me opened")
    }

    private func hide() {
        stopWatching()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.sing.isOpen else { return }
                panel.orderOut(nil)
                // Nothing stays behind: the view and its observers go with the window.
                panel.contentView = nil
                self.panel = nil
            }
        })
    }

    private func makePanel() -> LyricsPanel {
        let panel = LyricsPanel()
        let view = LyricsView(sing: sing, window: state, model: model, actions: LyricsActions(
            close: { [weak self] in self?.sing.close() },
            choose: { [weak self] in self?.choose($0) },
            beginMove: { [weak self] in self?.beginMove() },
            move: { [weak self] in self?.move() },
            endMove: { [weak self] in self?.endMove() }))
        let host = FirstClickHostingView(rootView: view)
        let container = LyricsResizingView(host: host)
        container.bounds_ = { [weak self] in self?.state.screen?.bounds ?? .zero }
        container.onFrame = { [weak self] frame, done in self?.setFrame(frame, save: done) }
        panel.contentView = container
        self.panel = panel
        return panel
    }

    private func setFrame(_ frame: CGRect, save: Bool) {
        guard let panel else { return }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if state.frame != frame { state.frame = frame }
        guard save, let screen = state.screen else { return }
        let preset = state.preset
        let relative = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        sing.setPlacement(LyricsPlacement(preset: preset, frame: preset == .custom ? relative : nil), for: screen.id)
    }

    private func choose(_ preset: LyricsPreset) {
        guard let screen = state.screen, preset != .custom else { return }
        let target = screen.frame(for: LyricsPlacement(preset: preset))
        sing.setPlacement(LyricsPlacement(preset: preset), for: screen.id)
        animate(to: target)
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

    // MARK: - Moving by the header

    private func beginMove() {
        guard let panel else { return }
        moveStart = (panel.frame, NSEvent.mouseLocation)
    }

    private func move() {
        guard let start = moveStart, let bounds = state.screen?.bounds else { return }
        let mouse = NSEvent.mouseLocation
        let moved = start.frame.offsetBy(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y)
        setFrame(LyricsGeometry.clamp(moved, to: bounds), save: false)
    }

    private func endMove() {
        guard moveStart != nil, let panel else { return }
        moveStart = nil
        setFrame(panel.frame, save: true)
    }

    // MARK: - While open

    private func watchWhileOpen() {
        stopWatching()
        // Settings typed a size, or Reset Size: follow it.
        whileOpen.append(sing.$placements.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = self.state.screen, self.moveStart == nil else { return }
                let target = screen.frame(for: self.sing.placement(for: screen.id))
                if target != self.state.frame { self.animate(to: target) }
            }
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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // Escape closes it: in other apps when LiveIsland may watch keys, and always in its own
        // windows. The panel itself never takes the keyboard.
        let key: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == Self.escape else { return false }
            MainActor.assumeIsolated { self?.sing.close() }
            return true
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = key($0) }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0) ? nil : $0 }) { monitors.append(monitor) }
    }

    private func stopWatching() {
        whileOpen.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        moveStart = nil
    }

    private func screensChanged() {
        guard sing.isOpen, let screen = LyricsScreen.current(for: model.islandDisplay) else { return }
        state.screen = screen
        setFrame(screen.frame(for: sing.placement(for: screen.id)), save: false)
    }
}
