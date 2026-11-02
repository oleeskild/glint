import AppKit

/// Full-screen crosshair overlay on every display. Drag to pick an area, Space to switch to window
/// picking, Esc to cancel. When given frozen screenshots it shows them (so the capture is exactly
/// what you saw) and draws a pixel magnifier.
@MainActor
final class SelectionSession {
    enum Result {
        case area(cgRect: CGRect, image: CGImage?, screen: NSScreen)
        case window(id: CGWindowID, cgRect: CGRect, image: CGImage?, screen: NSScreen)
    }

    struct WindowInfo {
        let id: CGWindowID
        let cgRect: CGRect
    }

    static private(set) var active: SelectionSession?
    private(set) var isFinished = false

    var windowMode: Bool
    let allowWindowMode: Bool
    let hint: String
    var mouseCG: CGPoint = .zero
    let windowInfos: [WindowInfo]
    private var overlays: [NSWindow] = []
    private let frozen: [CGDirectDisplayID: CGImage]
    private let completion: (Result?) -> Void

    init(windowMode: Bool, allowWindowMode: Bool, frozen: [CGDirectDisplayID: CGImage], hint: String,
         completion: @escaping (Result?) -> Void) {
        self.windowMode = windowMode
        self.allowWindowMode = allowWindowMode
        self.frozen = frozen
        self.hint = hint
        self.completion = completion
        self.windowInfos = SelectionSession.listWindows()
    }

    static func listWindows() -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b),
                  rect.width > 40, rect.height > 40 else { return nil }
            return WindowInfo(id: id, cgRect: rect)
        }
    }

    func begin() {
        SelectionSession.active = self
        mouseCG = Geo.flip(NSEvent.mouseLocation)
        let mouseScreen = NSScreen.withMouse()
        for screen in NSScreen.screens {
            let w = OverlayWindow(screen: screen)
            let v = OverlayView(session: self, screen: screen, frozen: frozen[screen.displayID])
            w.contentView = v
            w.orderFrontRegardless()
            overlays.append(w)
            if screen == mouseScreen {
                w.makeKey()
                w.makeFirstResponder(v)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()
    }

    func windowAt(_ p: CGPoint) -> WindowInfo? { windowInfos.first { $0.cgRect.contains(p) } }

    func redraw() { overlays.forEach { $0.contentView?.needsDisplay = true } }

    func finish(_ result: Result?) {
        guard !isFinished else { return }
        isFinished = true
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        SelectionSession.active = nil
        NSCursor.arrow.set()
        completion(result)
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    // Strong on purpose: AppKit can still deliver queued events (e.g. a mouse move) to this view after the
    // session has finished, and an unowned reference to the freed session aborted the app right there.
    let session: SelectionSession
    let screen: NSScreen
    let frozen: CGImage?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(session: SelectionSession, screen: NSScreen, frozen: CGImage?) {
        self.session = session
        self.screen = screen
        self.frozen = frozen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: coordinates

    private func toCG(_ local: CGPoint) -> CGPoint {
        Geo.flip(CGPoint(x: local.x + screen.frame.minX, y: local.y + screen.frame.minY))
    }

    private func fromCG(_ r: CGRect) -> CGRect {
        Geo.flip(r).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private var selection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return Geo.rect(a, b).intersection(bounds)
    }

    private func crop(_ local: CGRect) -> CGImage? {
        guard let frozen else { return nil }
        let s = CGFloat(frozen.width) / bounds.width
        let px = CGRect(x: local.minX * s, y: (bounds.height - local.maxY) * s,
                        width: local.width * s, height: local.height * s).integral
        return frozen.cropping(to: px)
    }

    private var hoveredWindowLocal: CGRect? {
        guard let w = session.windowAt(session.mouseCG) else { return nil }
        return fromCG(w.cgRect)
    }

    // MARK: events

    override func mouseMoved(with event: NSEvent) {
        guard !session.isFinished else { return }
        session.mouseCG = toCG(convert(event.locationInWindow, from: nil))
        NSCursor.crosshair.set()
        session.redraw()
    }

    override func mouseDown(with event: NSEvent) {
        guard !session.isFinished else { return }
        let p = convert(event.locationInWindow, from: nil)
        if session.windowMode {
            pickWindow(at: toCG(p))
            return
        }
        dragStart = p
        dragCurrent = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragCurrent = CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        session.mouseCG = toCG(dragCurrent!)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !session.isFinished else { return }
        guard !session.windowMode, let sel = selection else { return }
        dragStart = nil
        dragCurrent = nil
        if sel.width < 4 || sel.height < 4 {
            // A plain click: grab the window under the cursor, or the whole display.
            let cg = toCG(convert(event.locationInWindow, from: nil))
            if session.allowWindowMode, session.windowAt(cg) != nil {
                pickWindow(at: cg)
            } else {
                session.finish(.area(cgRect: CGDisplayBounds(screen.displayID), image: frozen, screen: screen))
            }
            return
        }
        let r = sel.integral
        session.finish(.area(cgRect: Geo.flip(r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)),
                             image: crop(r), screen: screen))
    }

    private func pickWindow(at cg: CGPoint) {
        guard let w = session.windowAt(cg) else { return }
        let local = fromCG(w.cgRect).intersection(bounds)
        session.finish(.window(id: w.id, cgRect: w.cgRect, image: crop(local), screen: screen))
    }

    override func keyDown(with event: NSEvent) {
        guard !session.isFinished else { return }
        switch event.keyCode {
        case 53: session.finish(nil) // esc
        case 49: // space
            if session.allowWindowMode && dragStart == nil {
                session.windowMode.toggle()
                session.redraw()
            }
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) { session.finish(nil) }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let frozen { ctx.draw(frozen, in: bounds) }

        let dim = NSColor.black.withAlphaComponent(0.38)
        let mouseLocal = fromCG(CGRect(origin: session.mouseCG, size: .zero)).origin
        let mouseHere = bounds.contains(mouseLocal)

        if session.windowMode {
            let hole = hoveredWindowLocal
            dimAll(except: hole, color: dim)
            if let hole {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                hole.fill()
                NSColor.controlAccentColor.setStroke()
                let p = NSBezierPath(rect: hole.insetBy(dx: 1, dy: 1))
                p.lineWidth = 2
                p.stroke()
            }
            if mouseHere { drawHint("Click a window to capture · Space for area · Esc to cancel", near: mouseLocal) }
            return
        }

        if let sel = selection {
            dimAll(except: sel, color: dim)
            NSColor.white.setStroke()
            let p = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            p.lineWidth = 1
            p.stroke()
            let scale = frozen.map { CGFloat($0.width) / bounds.width } ?? screen.backingScaleFactor
            drawBadge("\(Int(sel.width)) × \(Int(sel.height))" + (scale > 1 ? "  @\(Int(scale))x" : ""),
                      below: sel)
        } else {
            dimAll(except: nil, color: dim)
        }

        if mouseHere {
            drawCrosshair(at: mouseLocal)
            if frozen != nil { drawMagnifier(at: mouseLocal) }
            if selection == nil { drawHint(session.hint, near: mouseLocal) }
        }
    }

    private func dimAll(except hole: CGRect?, color: NSColor) {
        color.setFill()
        let path = NSBezierPath(rect: bounds)
        if let hole {
            path.appendRect(hole)
            path.windingRule = .evenOdd
        }
        path.fill()
    }

    private func drawCrosshair(at p: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: p.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.width, y: p.y.rounded() + 0.5))
        path.move(to: CGPoint(x: p.x.rounded() + 0.5, y: 0))
        path.line(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.height))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
    }

    private func drawMagnifier(at p: CGPoint) {
        guard let frozen else { return }
        let s = CGFloat(frozen.width) / bounds.width
        let samplePx: CGFloat = 15
        let size: CGFloat = 120
        let src = CGRect(x: (p.x * s - samplePx / 2).rounded(), y: ((bounds.height - p.y) * s - samplePx / 2).rounded(),
                         width: samplePx, height: samplePx)
        guard let piece = frozen.cropping(to: src) else { return }

        var origin = CGPoint(x: p.x + 24, y: p.y - size - 24)
        if origin.x + size > bounds.width - 8 { origin.x = p.x - size - 24 }
        if origin.y < 8 { origin.y = p.y + 24 }
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        clip.addClip()
        ctx.interpolationQuality = .none
        ctx.draw(piece, in: box)
        // pixel grid + center pixel
        let cell = size / samplePx
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let grid = NSBezierPath()
        for i in 1..<Int(samplePx) {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: box.minX + o, y: box.minY)); grid.line(to: CGPoint(x: box.minX + o, y: box.maxY))
            grid.move(to: CGPoint(x: box.minX, y: box.minY + o)); grid.line(to: CGPoint(x: box.maxX, y: box.minY + o))
        }
        grid.lineWidth = 0.5
        grid.stroke()
        ctx.restoreGState()
        let center = CGRect(x: box.minX + 7 * cell, y: box.minY + 7 * cell, width: cell, height: cell)
        NSColor.white.setStroke()
        NSBezierPath(rect: center).stroke()
        let border = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        border.lineWidth = 2
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()

        let cg = toCG(p)
        let local = CGPoint(x: cg.x - CGDisplayBounds(screen.displayID).minX, y: cg.y - CGDisplayBounds(screen.displayID).minY)
        drawBadge("\(Int(local.x)), \(Int(local.y))", below: box)
    }

    private func drawBadge(_ text: String, below r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        var box = CGRect(x: r.midX - sz.width / 2 - 8, y: r.minY - sz.height - 14, width: sz.width + 16, height: sz.height + 6)
        if box.minY < 4 { box.origin.y = r.maxY + 8 }
        box.origin.x = min(max(box.minX, 4), bounds.width - box.width - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        str.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }

    private func drawHint(_ text: String, near p: CGPoint) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        let box = CGRect(x: bounds.midX - sz.width / 2 - 12, y: bounds.maxY - 90, width: sz.width + 24, height: sz.height + 10)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        str.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 5))
    }
}
