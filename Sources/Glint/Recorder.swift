import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records a screen region to an H.264 .mp4 using ScreenCaptureKit + AVAssetWriter.
/// Glint's own windows (recording frame, toasts, quick access) are excluded from the video.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var lastPTS = CMTime.zero
    private let queue = DispatchQueue(label: "glint.recorder")
    private(set) var outputURL: URL?
    var onStreamError: ((Error) -> Void)?

    func start(cgRect: CGRect, screen: NSScreen, showCursor: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.windowNotFound
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let displayBounds = CGDisplayBounds(screen.displayID)
        let local = cgRect.intersection(displayBounds).offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        let scale = screen.backingScaleFactor
        let even = { (v: CGFloat) in max(2, Int(v * scale) / 2 * 2) }
        let width = even(local.width), height = even(local.height)

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB

        let folder = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ImgIO.uniqueURL(in: folder, name: ImgIO.fileName("mp4", prefix: "Glint Recording"))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        self.writer = writer
        self.input = input
        self.outputURL = url
        self.started = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async -> URL? {
        guard let stream else { return nil }
        try? await stream.stopCapture()
        self.stream = nil
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                guard let writer, let input, started else {
                    writer?.cancelWriting()
                    cont.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: lastPTS)
                writer.finishWriting { [self] in
                    let ok = writer.status == .completed
                    self.writer = nil
                    self.input = nil
                    cont.resume(returning: ok ? outputURL : nil)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let writer, let input,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = sb.presentationTimeStamp
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sb) { lastPTS = pts }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    static func thumbnail(for url: URL) async -> NSImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        if let (img, _) = try? await gen.image(at: .zero) {
            return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        }
        return NSImage(systemSymbolName: "film", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Dashed border shown around the area being recorded (not captured itself).
final class RecordingFrame: NSWindow {
    init(cocoaRect: CGRect) {
        let frame = cocoaRect.insetBy(dx: -3, dy: -3)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        level = .statusBar
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = FrameView(frame: NSRect(origin: .zero, size: frame.size))
    }

    final class FrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            p.lineWidth = 2
            p.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            p.stroke()
        }
    }
}
