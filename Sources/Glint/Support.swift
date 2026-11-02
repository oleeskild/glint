import AppKit
import UniformTypeIdentifiers

// MARK: - Preferences

enum Prefs {
    static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "copyToClipboard": true,
            "saveToDisk": true,
            "showQuickAccess": true,
            "playSound": true,
            "quickAccessAutoClose": 20,
            "saveFolder": (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"),
        ])
    }

    static var copyToClipboard: Bool { d.bool(forKey: "copyToClipboard") }
    static var saveToDisk: Bool { d.bool(forKey: "saveToDisk") }
    static var showQuickAccess: Bool { d.bool(forKey: "showQuickAccess") }
    static var playSound: Bool { d.bool(forKey: "playSound") }
    static var quickAccessAutoClose: Int { d.integer(forKey: "quickAccessAutoClose") }
    static var saveFolder: URL {
        URL(fileURLWithPath: d.string(forKey: "saveFolder") ?? NSHomeDirectory())
    }
}

// MARK: - Geometry

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func withMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    static func forCGRect(_ r: CGRect) -> NSScreen? {
        let mid = CGPoint(x: r.midX, y: r.midY)
        return screens.first { CGDisplayBounds($0.displayID).contains(mid) }
    }
}

enum Geo {
    /// Cocoa global (bottom-left origin) <-> CoreGraphics global (top-left origin). Symmetric.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: NSScreen.primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func flip(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: NSScreen.primaryHeight - p.y)
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: - Image I/O

enum ImgIO {
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        return (img, max(1, (dpi / 72).rounded()))
    }

    static func fileName(_ ext: String, prefix: String = "Glint") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: Date())).\(ext)"
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    static var tempFolder: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("Glint", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func nsImage(_ img: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
    }
}

// MARK: - Capture model

@MainActor
final class Capture {
    var image: CGImage?
    var scale: CGFloat
    var fileURL: URL?
    let videoURL: URL?
    let thumbnail: NSImage

    init(image: CGImage, scale: CGFloat, fileURL: URL?) {
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
        self.videoURL = nil
        self.thumbnail = ImgIO.nsImage(image, scale: scale)
    }

    init(videoURL: URL, thumbnail: NSImage) {
        self.image = nil
        self.scale = 1
        self.fileURL = videoURL
        self.videoURL = videoURL
        self.thumbnail = thumbnail
    }

    var isVideo: Bool { videoURL != nil }

    /// A file on disk for drag-and-drop; writes a temp PNG if the capture wasn't saved.
    func ensureFile() -> URL? {
        if let u = fileURL, FileManager.default.fileExists(atPath: u.path) { return u }
        guard let image, let data = ImgIO.pngData(image, scale: scale) else { return nil }
        let u = ImgIO.uniqueURL(in: ImgIO.tempFolder, name: ImgIO.fileName("png"))
        try? data.write(to: u)
        return u
    }

    @discardableResult
    func saveToFolder() -> URL? {
        if let u = fileURL, !u.path.hasPrefix(ImgIO.tempFolder.path) { return u }
        guard let image, let data = ImgIO.pngData(image, scale: scale) else { return nil }
        let folder = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let u = ImgIO.uniqueURL(in: folder, name: ImgIO.fileName("png"))
        do { try data.write(to: u) } catch { return nil }
        fileURL = u
        return u
    }

    func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let videoURL {
            pb.writeObjects([videoURL as NSURL])
            return
        }
        guard let image else { return }
        pb.writeObjects([ImgIO.nsImage(image, scale: scale)])
        if let png = ImgIO.pngData(image, scale: scale) { pb.setData(png, forType: .png) }
    }
}

// MARK: - Sound

enum Sounds {
    static let shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    static func playShutter() {
        guard Prefs.playSound else { return }
        shutter?.stop()
        shutter?.play()
    }
}

// MARK: - Toast HUD

@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 18)
        let size = stack.fittingSize
        let width = min(max(size.width, 160), 460)

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: size.height))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        stack.frame = fx.bounds
        stack.autoresizingMask = [.width, .height]
        fx.addSubview(stack)

        let screen = NSScreen.withMouse().visibleFrame
        let p = NSPanel(contentRect: NSRect(x: screen.midX - width / 2, y: screen.minY + 80, width: width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
            }
        }
    }
}
