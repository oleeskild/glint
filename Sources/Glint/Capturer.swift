import AppKit
import Carbon
import ScreenCaptureKit
import Vision

// MARK: - Global hotkeys (Carbon)

@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x474C_4E54), id: id) // 'GLNT'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            handlers[id] = handler
            refs.append(ref)
        }
        return handlers[id] != nil
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}

// MARK: - Screen capture

enum CaptureError: LocalizedError {
    case windowNotFound
    var errorDescription: String? { "The window is no longer available." }
}

enum Capturer {
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    static func captureRect(_ cgRect: CGRect) async throws -> CGImage {
        try await SCScreenshotManager.captureImage(in: cgRect)
    }

    static func captureDisplay(_ id: CGDirectDisplayID) async throws -> CGImage {
        try await SCScreenshotManager.captureImage(in: CGDisplayBounds(id))
    }

    /// Captures one window on its own (transparent background, with shadow), like a native ⇧⌘4-Space capture.
    static func captureWindow(_ windowID: CGWindowID, shadow: Bool = true) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = !shadow
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - Text recognition

enum OCR {
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}
