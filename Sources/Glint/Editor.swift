import AppKit
import CoreImage

// MARK: - Model

enum Tool: String, CaseIterable {
    case select, arrow, line, rect, ellipse, pen, highlighter, text, counter, pixelate, crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rect: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .pixelate: "x"
        case .crop: "c"
        }
    }

    var title: String {
        switch self {
        case .select: "Select & move"
        case .rect: "Rectangle"
        case .counter: "Counter"
        default: rawValue.capitalized
        }
    }
}

final class Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat // in image pixels
    var text = ""
    var number = 0

    init(tool: Tool, start: CGPoint, color: NSColor, width: CGFloat) {
        self.tool = tool
        self.start = start
        self.end = start
        self.points = [start]
        self.color = color
        self.width = width
    }

    func copy() -> Annotation {
        let a = Annotation(tool: tool, start: start, color: color, width: width)
        a.end = end
        a.points = points
        a.text = text
        a.number = number
        return a
    }

    var rect: CGRect { Geo.rect(start, end) }
    var fontSize: CGFloat { width * 4 + 8 }
    var counterRadius: CGFloat { width * 2.4 + 6 }

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = width * 0.8
        shadow.shadowOffset = NSSize(width: 0, height: -width * 0.2)
        return [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color, .shadow: shadow]
    }

    var textRect: CGRect {
        let s = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes).size()
        return CGRect(x: start.x, y: start.y - s.height, width: s.width, height: s.height)
    }

    var bounds: CGRect {
        switch tool {
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -width * (tool == .highlighter ? 2 : 0.5), dy: -width * (tool == .highlighter ? 2 : 0.5))
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .text:
            return textRect
        default:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    func hitTest(_ p: CGPoint, slop: CGFloat) -> Bool {
        switch tool {
        case .arrow, .line:
            return distance(p, toSegment: start, end) < width + slop
        case .rect, .ellipse:
            let outer = rect.insetBy(dx: -width - slop, dy: -width - slop)
            let inner = rect.insetBy(dx: width + slop, dy: width + slop)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        case .pen, .highlighter:
            return zip(points, points.dropFirst()).contains { distance(p, toSegment: $0, $1) < width * (tool == .highlighter ? 2 : 1) + slop }
        default:
            return bounds.insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    func move(by d: CGVector) {
        start = CGPoint(x: start.x + d.dx, y: start.y + d.dy)
        end = CGPoint(x: end.x + d.dx, y: end.y + d.dy)
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
}

private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: - Rendering (shared by canvas and export)

enum Renderer {
    static func draw(_ a: Annotation, ctx: CGContext, pixelated: CGImage?, imageSize: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let w = a.width
        let shadow = { ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.25), blur: w * 1.2,
                                     color: NSColor.black.withAlphaComponent(0.35).cgColor) }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(w)

        switch a.tool {
        case .arrow:
            shadow()
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: w))
            ctx.fillPath()
        case .line:
            shadow()
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rect:
            shadow()
            let r = a.rect
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(w, r.width / 2), cornerHeight: min(w, r.height / 2), transform: nil))
            ctx.strokePath()
        case .ellipse:
            shadow()
            ctx.strokeEllipse(in: a.rect)
        case .pen:
            shadow()
            ctx.addLines(between: a.points)
            ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(w * 4)
            ctx.setLineCap(.square)
            ctx.addLines(between: a.points)
            ctx.strokePath()
        case .text:
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: a.text, attributes: a.textAttributes).draw(at: a.textRect.origin)
            NSGraphicsContext.restoreGraphicsState()
        case .counter:
            shadow()
            let r = a.counterRadius
            ctx.fillEllipse(in: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(1, w * 0.4))
            ctx.strokeEllipse(in: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2).insetBy(dx: w * 0.2, dy: w * 0.2))
            let str = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ])
            let s = str.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(at: CGPoint(x: a.start.x - s.width / 2, y: a.start.y - s.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate:
            ctx.clip(to: a.rect)
            if let pixelated {
                ctx.draw(pixelated, in: CGRect(origin: .zero, size: imageSize))
            } else {
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(a.rect)
            }
        case .select, .crop:
            break
        }
    }

    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let len = hypot(b.x - a.x, b.y - a.y)
        let path = CGMutablePath()
        guard len > 0.5 else { return path }
        let headLen = min(w * 4.5 + 6, len * 0.6)
        let headHalf = headLen * 0.62
        let angle = atan2(b.y - a.y, b.x - a.x)
        let t = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: angle)
        // Tapered shaft (thin at the tail) plus a solid head, in arrow-local coordinates.
        let base = len - headLen
        let tail = w * 0.25
        let neck = w * 0.6
        let pts = [
            CGPoint(x: 0, y: -tail), CGPoint(x: base, y: -neck), CGPoint(x: base - headLen * 0.12, y: -headHalf),
            CGPoint(x: len, y: 0),
            CGPoint(x: base - headLen * 0.12, y: headHalf), CGPoint(x: base, y: neck), CGPoint(x: 0, y: tail),
        ]
        path.addLines(between: pts, transform: t)
        path.closeSubpath()
        return path
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }
}

// MARK: - Canvas

@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let base: CGImage
    let pxScale: CGFloat
    var items: [Annotation] = []
    var cropRect: CGRect?
    var tool: Tool = .arrow { didSet { selected = nil; commitText(); needsDisplay = true; onChange?() } }
    var color: NSColor = .systemRed { didSet { if let selected { pushUndo(); selected.color = color; needsDisplay = true } } }
    var strokePoints: CGFloat = 4 { didSet { if let selected { pushUndo(); selected.width = strokePoints * pxScale; needsDisplay = true } } }
    var onChange: (() -> Void)?

    private var undoStack: [([Annotation], CGRect?)] = []
    private var redoStack: [([Annotation], CGRect?)] = []
    private var current: Annotation?
    private var selected: Annotation?
    private var dragLast: CGPoint?
    private var cropStart: CGPoint?
    private var movedSinceDown = false
    private var textField: NSTextField?
    private var editingText: Annotation?
    private lazy var pixelated: CGImage? = makePixelated()

    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: CGImage, scale: CGFloat) {
        base = image
        pxScale = scale
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: geometry

    private var k: CGFloat {
        let avail = bounds.insetBy(dx: 28, dy: 28)
        return max(0.01, min(avail.width / imageSize.width, avail.height / imageSize.height, 1 / pxScale))
    }

    private var fitRect: CGRect {
        let s = CGSize(width: imageSize.width * k, height: imageSize.height * k)
        return CGRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height).integral
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let f = fitRect
        return CGPoint(x: (p.x - f.minX) / k, y: (p.y - f.minY) / k)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let f = fitRect
        return CGPoint(x: f.minX + p.x * k, y: f.minY + p.y * k)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * k, height: r.height * k)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        repositionTextField()
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = fitRect

        // checkerboard behind transparent captures (window shots)
        ctx.saveGState()
        ctx.clip(to: f)
        NSColor(white: 0.2, alpha: 1).setFill()
        f.fill()
        NSColor(white: 0.26, alpha: 1).setFill()
        let cell: CGFloat = 10
        var y = f.minY
        var row = 0
        while y < f.maxY {
            var x = f.minX + (row % 2 == 0 ? 0 : cell)
            while x < f.maxX { CGRect(x: x, y: y, width: cell, height: cell).fill(); x += cell * 2 }
            y += cell
            row += 1
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: f.minX, y: f.minY)
        ctx.scaleBy(x: k, y: k)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(origin: .zero, size: imageSize))
        for a in items where a !== editingText {
            Renderer.draw(a, ctx: ctx, pixelated: pixelated, imageSize: imageSize)
        }
        if let current { Renderer.draw(current, ctx: ctx, pixelated: pixelated, imageSize: imageSize) }
        ctx.restoreGState()

        if let selected {
            let r = toView(selected.bounds).insetBy(dx: -4, dy: -4)
            let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            p.setLineDash([5, 3], count: 2, phase: 0)
            p.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            p.stroke()
        }

        if let crop = cropRect {
            let v = toView(crop)
            NSColor.black.withAlphaComponent(0.55).setFill()
            let path = NSBezierPath(rect: f)
            path.appendRect(v)
            path.windingRule = .evenOdd
            path.fill()
            let border = NSBezierPath(rect: v)
            border.lineWidth = 1.5
            NSColor.white.setStroke()
            border.stroke()
            let label = NSAttributedString(string: "\(Int(crop.width / pxScale)) × \(Int(crop.height / pxScale))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            label.draw(at: CGPoint(x: v.minX + 6, y: v.maxY - 18))
        }
    }

    // MARK: undo

    func pushUndo() {
        undoStack.append((items.map { $0.copy() }, cropRect))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        onChange?()
    }

    @objc func undo() {
        commitText()
        guard let s = undoStack.popLast() else { return }
        redoStack.append((items.map { $0.copy() }, cropRect))
        (items, cropRect) = s
        selected = nil
        needsDisplay = true
        onChange?()
    }

    @objc func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append((items.map { $0.copy() }, cropRect))
        (items, cropRect) = s
        selected = nil
        needsDisplay = true
        onChange?()
    }

    func resetCrop() {
        guard cropRect != nil else { return }
        pushUndo()
        cropRect = nil
        needsDisplay = true
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textField != nil { commitText(); return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        let slop = 6 / k
        movedSinceDown = false

        switch tool {
        case .select:
            selected = items.reversed().first { $0.hitTest(p, slop: slop) }
            if let s = selected, s.tool == .text, event.clickCount == 2 { beginText(editing: s, at: s.start); return }
            dragLast = selected == nil ? nil : p
        case .text:
            if let hit = items.reversed().first(where: { $0.tool == .text && $0.hitTest(p, slop: slop) }) {
                beginText(editing: hit, at: hit.start)
            } else {
                beginText(editing: nil, at: p)
            }
        case .counter:
            pushUndo()
            let a = Annotation(tool: .counter, start: p, color: color, width: strokePoints * pxScale)
            a.number = (items.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
            items.append(a)
        case .crop:
            cropStart = p
        default:
            // clicking an existing shape with a drawing tool lets you move it instead of drawing on top
            if let hit = items.reversed().first(where: { $0.hitTest(p, slop: slop) }), event.modifierFlags.contains(.command) {
                selected = hit
                dragLast = p
            } else {
                current = Annotation(tool: tool, start: p, color: color, width: strokePoints * pxScale)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var p = toImage(convert(event.locationInWindow, from: nil))
        if let last = dragLast, let s = selected {
            if !movedSinceDown { pushUndo(); movedSinceDown = true }
            s.move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            dragLast = p
        } else if let current {
            if event.modifierFlags.contains(.shift) { p = constrain(p, from: current.start, tool: current.tool) }
            current.end = p
            if current.tool == .pen || current.tool == .highlighter { current.points.append(p) }
        } else if let cs = cropStart {
            let img = CGRect(origin: .zero, size: imageSize)
            let clamped = CGPoint(x: min(max(p.x, 0), img.width), y: min(max(p.y, 0), img.height))
            if !movedSinceDown { pushUndo(); movedSinceDown = true }
            cropRect = Geo.rect(cs, clamped).integral
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let c = current {
            let tiny = c.tool == .pen || c.tool == .highlighter ? c.points.count < 2 : max(c.rect.width, c.rect.height) < 3
            if !tiny {
                pushUndo()
                items.append(c)
            }
            current = nil
        }
        if cropStart != nil, let r = cropRect, r.width < 4 || r.height < 4 { cropRect = nil }
        cropStart = nil
        dragLast = nil
        needsDisplay = true
    }

    private func constrain(_ p: CGPoint, from s: CGPoint, tool: Tool) -> CGPoint {
        switch tool {
        case .rect, .ellipse, .pixelate:
            let d = max(abs(p.x - s.x), abs(p.y - s.y))
            return CGPoint(x: s.x + (p.x < s.x ? -d : d), y: s.y + (p.y < s.y ? -d : d))
        case .arrow, .line:
            let angle = (atan2(p.y - s.y, p.x - s.x) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(p.x - s.x, p.y - s.y)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        default:
            return p
        }
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 51 || event.keyCode == 117, let s = selected {
            pushUndo()
            items.removeAll { $0 === s }
            selected = nil
            needsDisplay = true
            return
        }
        if event.keyCode == 53 {
            if selected != nil { selected = nil; needsDisplay = true } else { window?.performClose(nil) }
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let t = Tool.allCases.first(where: { $0.key == chars }) {
            tool = t
            return
        }
        super.keyDown(with: event)
    }

    // MARK: text

    private func beginText(editing: Annotation?, at p: CGPoint) {
        let a: Annotation
        if let editing {
            a = editing
        } else {
            a = Annotation(tool: .text, start: p, color: color, width: strokePoints * pxScale)
        }
        editingText = a
        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = a.color
        field.font = NSFont.systemFont(ofSize: a.fontSize * k, weight: .bold)
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        textField = field
        repositionTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func repositionTextField() {
        guard let field = textField, let a = editingText else { return }
        field.font = NSFont.systemFont(ofSize: a.fontSize * k, weight: .bold)
        let font = field.font!
        let textW = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        let h = field.fittingSize.height
        let top = toView(a.start)
        field.frame = CGRect(x: top.x - 2, y: top.y - h, width: max(textW + font.pointSize * 2, 60), height: h)
    }

    func controlTextDidChange(_ obj: Notification) { repositionTextField() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func commitText() {
        guard let field = textField, let a = editingText else { return }
        textField = nil
        editingText = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        let existing = items.contains { $0 === a }
        if text.isEmpty {
            if existing { pushUndo(); items.removeAll { $0 === a } }
        } else if text != a.text || !existing {
            pushUndo()
            a.text = text
            if !existing { items.append(a) }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: export

    func renderFinal() -> CGImage? {
        commitText()
        let space = base.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(origin: .zero, size: imageSize))
        for a in items { Renderer.draw(a, ctx: ctx, pixelated: pixelated, imageSize: imageSize) }
        guard let full = ctx.makeImage() else { return nil }
        guard let c = cropRect else { return full }
        return full.cropping(to: CGRect(x: c.minX, y: imageSize.height - c.maxY, width: c.width, height: c.height))
    }

    private func makePixelated() -> CGImage? {
        let ci = CIImage(cgImage: base)
        let out = ci.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: max(8, 9 * pxScale),
            kCIInputCenterKey: CIVector(x: 0, y: 0),
        ]).cropped(to: ci.extent)
        return CIContext().createCGImage(out, from: ci.extent)
    }
}

// MARK: - Window

final class EditorWindow: NSWindow {
    weak var controller: EditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !(firstResponder is NSTextView),
              let controller else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": shift ? controller.canvas.redo() : controller.canvas.undo(); return true
        case "c": controller.copyImage(); return true
        case "s": controller.saveImage(); return true
        case "w": performClose(nil); return true
        case "p": controller.pinImage(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [EditorWindowController] = []
    static var hasOpenEditors: Bool { !open.isEmpty }
    let canvas: CanvasView
    private var sourceURL: URL?
    /// Only overwrite files Glint itself wrote (captures / earlier saves); never a user-opened image.
    private var ownsSource = false
    private var toolButtons: [Tool: ToolButton] = [:]
    private var colorButtons: [ColorButton] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var cropReset: NSButton!

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1),
        NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .white, .black,
    ]

    static func open(image: CGImage, scale: CGFloat, sourceURL: URL?) {
        let c = EditorWindowController(image: image, scale: scale, sourceURL: sourceURL)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(image: CGImage, scale: CGFloat, sourceURL: URL?) {
        canvas = CanvasView(image: image, scale: scale)
        self.sourceURL = sourceURL
        self.ownsSource = sourceURL.map { $0.deletingLastPathComponent().standardizedFileURL == Prefs.saveFolder.standardizedFileURL && $0.lastPathComponent.hasPrefix("Glint") } ?? false
        let vf = NSScreen.withMouse().visibleFrame
        let toolbarH: CGFloat = 52
        let want = CGSize(width: CGFloat(image.width) / scale + 56, height: CGFloat(image.height) / scale + 56 + toolbarH)
        let size = CGSize(width: min(max(want.width, 820), vf.width * 0.9), height: min(max(want.height, 480), vf.height * 0.9))
        let w = EditorWindow(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                                                 width: size.width, height: size.height),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = sourceURL?.lastPathComponent ?? "Annotate"
        w.minSize = NSSize(width: 820, height: 360)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.controller = self
        w.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let toolbar = buildToolbar(width: size.width, height: toolbarH)
        toolbar.frame = NSRect(x: 0, y: root.bounds.height - toolbarH, width: size.width, height: toolbarH)
        toolbar.autoresizingMask = [.width, .minYMargin]
        canvas.frame = NSRect(x: 0, y: 0, width: size.width, height: root.bounds.height - toolbarH)
        canvas.autoresizingMask = [.width, .height]
        root.addSubview(canvas)
        root.addSubview(toolbar)
        w.contentView = root
        w.makeFirstResponder(canvas)
        canvas.onChange = { [weak self] in self?.refreshToolbar() }
        refreshToolbar()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow

        var left: [NSView] = []
        for t in Tool.allCases {
            let b = ToolButton(symbol: t.symbol, tip: "\(t.title) (\(t.key.uppercased()))", target: self, action: #selector(pickTool(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
            toolButtons[t] = b
            left.append(b)
            if t == .select || t == .ellipse || t == .text || t == .pixelate { left.append(Divider()) }
        }
        cropReset = NSButton(title: "Reset crop", target: self, action: #selector(resetCrop))
        cropReset.bezelStyle = .push
        cropReset.controlSize = .small
        left.append(cropReset)
        left.append(Divider())

        for (i, c) in Self.palette.enumerated() {
            let b = ColorButton(color: c, target: self, action: #selector(pickColor(_:)))
            b.tag = i
            colorButtons.append(b)
            left.append(b)
        }
        let size = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: self, action: #selector(pickSize(_:)))
        size.selectedSegment = 1
        size.controlSize = .small
        size.toolTip = "Stroke size"
        left.append(size)

        undoButton = ToolButton(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)", target: canvas, action: #selector(CanvasView.undo))
        redoButton = ToolButton(symbol: "arrow.uturn.forward", tip: "Redo (⇧⌘Z)", target: canvas, action: #selector(CanvasView.redo))
        let pin = ToolButton(symbol: "pin", tip: "Pin to screen (⌘P)", target: self, action: #selector(pinImage))
        let copy = ToolButton(symbol: "doc.on.doc", tip: "Copy (⌘C)", target: self, action: #selector(copyImage))
        let save = ToolButton(symbol: "square.and.arrow.down", tip: "Save (⌘S)", target: self, action: #selector(saveImage))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        done.toolTip = "Copy, save and close"

        let leftStack = NSStackView(views: left)
        leftStack.spacing = 4
        let rightStack = NSStackView(views: [undoButton, redoButton, Divider(), pin, copy, save, done])
        rightStack.spacing = 4
        for s in [leftStack, rightStack] {
            s.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(s)
        }
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
        ])
        let line = NSBox()
        line.boxType = .separator
        line.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        line.autoresizingMask = [.width]
        bar.addSubview(line)
        return bar
    }

    private func refreshToolbar() {
        for (t, b) in toolButtons { b.isSelectedTool = t == canvas.tool }
        for b in colorButtons { b.isChosen = b.color == canvas.color }
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        cropReset.isHidden = canvas.cropRect == nil && canvas.tool != .crop
        cropReset.isEnabled = canvas.cropRect != nil
    }

    @objc private func pickTool(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let t = Tool(rawValue: raw) else { return }
        canvas.tool = t
        window?.makeFirstResponder(canvas)
    }

    @objc private func pickColor(_ sender: NSButton) {
        canvas.color = Self.palette[sender.tag]
        refreshToolbar()
    }

    @objc private func pickSize(_ sender: NSSegmentedControl) {
        canvas.strokePoints = [2.5, 4, 7][sender.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    @objc private func resetCrop() {
        canvas.resetCrop()
        refreshToolbar()
    }

    @objc func copyImage() {
        guard let img = canvas.renderFinal() else { return }
        Capture(image: img, scale: canvas.pxScale, fileURL: nil).copyToClipboard()
        Toast.show("Copied to clipboard")
    }

    @objc func saveImage() {
        guard let img = canvas.renderFinal(), let data = ImgIO.pngData(img, scale: canvas.pxScale) else { return }
        let url: URL
        if let s = sourceURL, ownsSource {
            url = s
        } else {
            try? FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
            url = ImgIO.uniqueURL(in: Prefs.saveFolder, name: ImgIO.fileName("png"))
        }
        do {
            try data.write(to: url)
            sourceURL = url
            ownsSource = true
            window?.title = url.lastPathComponent
            Toast.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func pinImage() {
        guard let img = canvas.renderFinal() else { return }
        PinWindow.pin(img, scale: canvas.pxScale)
    }

    @objc private func done() {
        copyImage()
        if Prefs.saveToDisk { saveImage() }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.open.removeAll { $0 === self }
        if EditorWindowController.open.isEmpty && !SettingsWindow.isOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Toolbar controls

final class ToolButton: NSButton {
    var isSelectedTool = false { didSet { updateLook() } }

    convenience init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        self.target = target
        self.action = action
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = .init(pointSize: 14, weight: .medium)
        imagePosition = .imageOnly
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        updateLook()
    }

    private func updateLook() {
        layer?.backgroundColor = isSelectedTool ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : nil
        contentTintColor = isSelectedTool ? .controlAccentColor : .labelColor
    }
}

final class ColorButton: NSButton {
    let color: NSColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: NSColor, target: AnyObject, action: Selector) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        let dot = NSBezierPath(ovalIn: r)
        dot.fill()
        NSColor.separatorColor.setStroke()
        dot.lineWidth = 1
        dot.stroke()
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

final class Divider: NSBox {
    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 1, height: 20))
        boxType = .separator
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }
}
