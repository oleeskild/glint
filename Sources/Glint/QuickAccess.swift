import AppKit

/// Stack of floating thumbnails in the bottom-left corner after every capture.
/// Two-finger swipe left on a thumbnail closes it; swipe down tucks the whole stack into a small tab.
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()
    private var panels: [QuickAccessPanel] = []
    private let maxItems = 6
    private var tab: HiddenStackTab?
    private(set) var isHidden = false

    private var visibleFrame: CGRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

    func show(_ capture: Capture) {
        if isHidden { unhide() }
        let panel = QuickAccessPanel(capture: capture)
        panels.insert(panel, at: 0)
        while panels.count > maxItems { remove(panels.last!) }
        let target = layout(placing: panel)
        panel.setFrame(target.offsetBy(dx: -target.width - 30, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func remove(_ panel: QuickAccessPanel, animated: Bool = true) {
        panel.stopTimer()
        panels.removeAll { $0 === panel }
        if animated && !isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().setFrame(panel.frame.offsetBy(dx: -panel.frame.width - 30, dy: 0), display: true)
                panel.animator().alphaValue = 0
            }) { panel.orderOut(nil); panel.contentView = nil }
        } else {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        if isHidden {
            if panels.isEmpty { unhide() } else { tab?.count = panels.count }
        } else {
            _ = layout(placing: nil)
        }
    }

    func closeAll() {
        if isHidden { unhide() }
        panels.forEach { remove($0) }
    }

    /// Slides every thumbnail below the screen edge and leaves a small tab to bring them back.
    func hideAll() {
        guard !panels.isEmpty, !isHidden else { return }
        isHidden = true
        let bottom = visibleFrame.minY
        for p in panels {
            p.stopTimer()
            let target = CGRect(x: p.frame.minX, y: bottom - p.frame.height - 40, width: p.frame.width, height: p.frame.height)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 0
            }) { [weak self] in if self?.isHidden == true { p.orderOut(nil) } }
        }
        let t = HiddenStackTab(count: panels.count, at: CGPoint(x: visibleFrame.minX + 18, y: visibleFrame.minY + 18))
        t.alphaValue = 0
        t.orderFrontRegardless()
        t.animator().alphaValue = 1
        tab = t
    }

    func unhide() {
        guard isHidden else { return }
        isHidden = false
        tab?.orderOut(nil)
        tab = nil
        let bottom = visibleFrame.minY
        for p in panels {
            p.setFrame(CGRect(x: p.frame.minX, y: bottom - p.frame.height - 40, width: p.frame.width, height: p.frame.height),
                       display: false)
            p.orderFrontRegardless()
            p.animator().alphaValue = 1
            p.restartTimer()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            _ = layout(placing: nil)
        }
    }

    /// Where a panel belongs in the stack right now.
    func homeFrame(of panel: QuickAccessPanel) -> CGRect {
        var y = visibleFrame.minY + 18
        for p in panels {
            if p === panel { return CGRect(x: visibleFrame.minX + 18, y: y, width: p.frame.width, height: p.frame.height) }
            y += p.frame.height + 12
        }
        return panel.frame
    }

    /// Lays out the stack and returns the target frame for `placing` (not animated itself).
    private func layout(placing: QuickAccessPanel?) -> CGRect {
        var result = CGRect.zero
        for p in panels {
            let f = homeFrame(of: p)
            if p === placing { result = f } else if p.frame != f { p.animator().setFrame(f, display: true) }
        }
        return result
    }
}

/// The little "N captures" tab left behind after swiping the stack away. Stays until clicked.
final class HiddenStackTab: NSPanel {
    static let size = NSSize(width: 76, height: 30)
    private let label = NSTextField(labelWithString: "")
    var count: Int { didSet { refresh() } }

    init(count: Int, at origin: CGPoint) {
        self.count = count
        super.init(contentRect: NSRect(origin: origin, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = TabView(frame: NSRect(origin: .zero, size: Self.size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = Self.size.height / 2
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        fx.toolTip = "Show captures (click or swipe up)"

        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        let photos = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)!)
        photos.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        for v in [chevron, photos] { v.contentTintColor = .labelColor }
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [chevron, photos, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: fx.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
        ])
        contentView = fx
        refresh()
    }

    private func refresh() { label.stringValue = "\(count)" }

    final class TabView: NSVisualEffectView {
        override func mouseDown(with event: NSEvent) { QuickAccess.shared.unhide() }
        override func scrollWheel(with event: NSEvent) {
            guard event.hasPreciseScrollingDeltas, event.phase == .changed else { return }
            let fingerDown = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
            if fingerDown < -4 { QuickAccess.shared.unhide() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

final class QuickAccessPanel: NSPanel {
    let capture: Capture
    private var timer: Timer?

    init(capture: Capture) {
        self.capture = capture
        let img = capture.thumbnail.size
        let width: CGFloat = 230
        let height = min(max(width * img.height / max(img.width, 1), 96), 280)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = QuickAccessView(panel: self)
        restartTimer()
    }

    override var canBecomeKey: Bool { true }

    func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard !QuickAccess.shared.isHidden else { return } // tucked away: stay until brought back
        let secs = Prefs.quickAccessAutoClose
        guard secs > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: false) { [weak self] _ in
            Task { @MainActor in if let self { QuickAccess.shared.remove(self) } }
        }
    }

    func stopTimer() { timer?.invalidate(); timer = nil }

    func dismiss() { QuickAccess.shared.remove(self) }
}

final class QuickAccessView: NSView, NSDraggingSource {
    // Strong (not unowned) so late AppKit events can never reach a freed panel; QuickAccess.remove
    // breaks the cycle by clearing the panel's contentView once it's off screen.
    let panel: QuickAccessPanel
    private let overlay = NSView()
    private var mouseDownAt: NSPoint?

    init(panel: QuickAccessPanel) {
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let imageLayer = CALayer()
        imageLayer.frame = bounds
        imageLayer.contents = panel.capture.thumbnail
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(imageLayer)

        if panel.capture.isVideo {
            let play = NSImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)!)
            play.symbolConfiguration = .init(pointSize: 34, weight: .regular)
            play.contentTintColor = .white
            play.frame = NSRect(x: bounds.midX - 20, y: bounds.midY - 20, width: 40, height: 40)
            addSubview(play)
        }

        overlay.frame = bounds
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        overlay.isHidden = true
        addSubview(overlay)
        buildButtons()

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildButtons() {
        let cap = panel.capture
        let main: [(String, Selector)] = cap.isVideo
            ? [("Copy", #selector(copyItem)), ("Show in Finder", #selector(reveal))]
            : [("Copy", #selector(copyItem)), ("Save", #selector(save))]
        let stack = NSStackView(views: main.map { PillButton(title: $0.0, target: self, action: $0.1) })
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: bounds.midX - 60, y: bounds.midY - 34, width: 120, height: 68)
        overlay.addSubview(stack)

        let close = IconButton(symbol: "xmark", tip: "Close", target: self, action: #selector(closeItem))
        close.frame.origin = CGPoint(x: 8, y: bounds.height - 32)
        overlay.addSubview(close)

        if !cap.isVideo {
            let pin = IconButton(symbol: "pin.fill", tip: "Pin to screen", target: self, action: #selector(pin))
            pin.frame.origin = CGPoint(x: bounds.width - 32, y: bounds.height - 32)
            overlay.addSubview(pin)
            let edit = IconButton(symbol: "pencil.tip", tip: "Annotate", target: self, action: #selector(annotate))
            edit.frame.origin = CGPoint(x: 8, y: 8)
            overlay.addSubview(edit)
            let text = IconButton(symbol: "text.viewfinder", tip: "Copy text (OCR)", target: self, action: #selector(copyText))
            text.frame.origin = CGPoint(x: bounds.width - 32, y: 8)
            overlay.addSubview(text)
        } else {
            let open = IconButton(symbol: "play.fill", tip: "Open", target: self, action: #selector(openVideo))
            open.frame.origin = CGPoint(x: bounds.width - 32, y: bounds.height - 32)
            overlay.addSubview(open)
        }
    }

    // MARK: hover

    override func mouseEntered(with event: NSEvent) {
        panel.stopTimer()
        overlay.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        overlay.isHidden = true
        panel.restartTimer()
    }

    // MARK: actions

    @objc private func copyItem() {
        panel.capture.copyToClipboard()
        Toast.show(panel.capture.isVideo ? "Video copied" : "Copied to clipboard")
        panel.dismiss()
    }

    @objc private func save() {
        if let url = panel.capture.saveToFolder() {
            Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill")
        }
        panel.dismiss()
    }

    @objc private func reveal() {
        if let u = panel.capture.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        panel.dismiss()
    }

    @objc private func openVideo() {
        if let u = panel.capture.videoURL { NSWorkspace.shared.open(u) }
        panel.dismiss()
    }

    @objc private func closeItem() { panel.dismiss() }

    @objc private func pin() {
        guard let img = panel.capture.image else { return }
        PinWindow.pin(img, scale: panel.capture.scale)
        panel.dismiss()
    }

    @objc private func annotate() {
        guard let img = panel.capture.image else { return }
        EditorWindowController.open(image: img, scale: panel.capture.scale, sourceURL: panel.capture.fileURL)
        panel.dismiss()
    }

    @objc private func copyText() {
        guard let img = panel.capture.image else { return }
        AppController.shared.recognizeText(in: img)
    }

    // MARK: two-finger swipes

    private var swipe = CGVector.zero
    private enum Axis { case none, horizontal, vertical }
    private var axis = Axis.none
    private var swipeOrigin = NSRect.zero
    private var swiping = false

    override func scrollWheel(with event: NSEvent) {
        // Trackpad gestures only; ignore mouse wheels and the momentum tail after the fingers lift.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began, .mayBegin:
            swipe = .zero
            axis = .none
            swipeOrigin = QuickAccess.shared.homeFrame(of: panel)
            swiping = true
            panel.stopTimer()
        case .changed where swiping:
            // Convert to finger movement (+x right, +y down) regardless of natural scrolling.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            swipe.dx += event.scrollingDeltaX * sign
            swipe.dy += event.scrollingDeltaY * sign
            if axis == .none {
                if abs(swipe.dx) > 6, abs(swipe.dx) > abs(swipe.dy) { axis = .horizontal }
                else if abs(swipe.dy) > 6 { axis = .vertical }
            }
            var f = swipeOrigin
            switch axis {
            case .horizontal:
                let dx = swipe.dx < 0 ? swipe.dx : swipe.dx * 0.15 // rubber-band to the right
                f.origin.x += dx
                panel.alphaValue = max(0.25, 1 + min(0, dx) / 220)
            case .vertical:
                f.origin.y -= swipe.dy > 0 ? swipe.dy : swipe.dy * 0.15
            case .none: break
            }
            panel.setFrame(f, display: true)
            // Commit as soon as the swipe is clearly past the threshold: once the thumbnail slides out
            // from under the pointer, the rest of the gesture is delivered to whatever window is there.
            if (axis == .horizontal && swipe.dx < -60) || (axis == .vertical && swipe.dy > 35) {
                finishSwipe()
            } else {
                settle?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.finishSwipe() }
                settle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        case .ended, .cancelled:
            finishSwipe()
        default:
            break
        }
    }

    private var settle: DispatchWorkItem?

    private func finishSwipe() {
        settle?.cancel()
        settle = nil
        guard swiping else { return }
        swiping = false
        if axis == .horizontal && swipe.dx < -60 {
            panel.dismiss()
        } else if axis == .vertical && swipe.dy > 35 {
            QuickAccess.shared.hideAll()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(swipeOrigin, display: true)
                panel.animator().alphaValue = 1
            }
            if overlay.isHidden { panel.restartTimer() } // if still hovered, the timer restarts on exit
        }
    }

    // MARK: drag out

    override func mouseDown(with event: NSEvent) { mouseDownAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4,
              let url = panel.capture.ensureFile() else { return }
        mouseDownAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: panel.capture.thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2, !panel.capture.isVideo { annotate() }
        else if event.clickCount == 2 { openVideo() }
        mouseDownAt = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { panel.dismiss() }
    }
}

final class PillButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
}

final class IconButton: NSButton {
    convenience init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        self.target = target
        self.action = action
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = .init(pointSize: 11, weight: .bold)
        contentTintColor = .black
        imagePosition = .imageOnly
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
    }
}

// MARK: - Pinned screenshots

final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    let image: CGImage
    let scale: CGFloat

    static func pin(_ image: CGImage, scale: CGFloat) {
        let w = PinWindow(image: image, scale: scale)
        open.append(w)
        w.makeKeyAndOrderFront(nil)
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        let vf = NSScreen.withMouse().visibleFrame
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, vf.width * 0.6 / size.width, vf.height * 0.6 / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        super.init(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                                       width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        let v = PinView(frame: NSRect(origin: .zero, size: size))
        v.image = ImgIO.nsImage(image, scale: scale)
        v.autoresizingMask = [.width, .height]
        contentView = v
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        var f = frame
        let newW = max(60, f.width * factor)
        let newH = newW * f.height / f.width
        f.origin.x -= (newW - f.width) / 2
        f.origin.y -= (newH - f.height) / 2
        f.size = CGSize(width: newW, height: newH)
        setFrame(f, display: true)
    }

    @objc func closePin() {
        orderOut(nil)
        PinWindow.open.removeAll { $0 === self }
    }

    @objc func copyPin() {
        let c = Capture(image: image, scale: scale, fileURL: nil)
        c.copyToClipboard()
        Toast.show("Copied to clipboard")
    }

    @objc func annotatePin() {
        EditorWindowController.open(image: image, scale: scale, sourceURL: nil)
        closePin()
    }

    @objc func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
}

final class PinView: NSImageView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { (window as? PinWindow)?.closePin(); return }
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let w = window as? PinWindow else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(PinWindow.copyPin), keyEquivalent: "").target = w
        m.addItem(withTitle: "Annotate", action: #selector(PinWindow.annotatePin), keyEquivalent: "").target = w
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pct in [100, 80, 60, 40] {
            let i = sub.addItem(withTitle: "\(pct)%", action: #selector(PinWindow.setOpacity(_:)), keyEquivalent: "")
            i.tag = pct
            i.target = w
            i.state = Int((w.alphaValue * 100).rounded()) == pct ? .on : .off
        }
        op.submenu = sub
        m.addItem(op)
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(PinWindow.closePin), keyEquivalent: "").target = w
        return m
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}
