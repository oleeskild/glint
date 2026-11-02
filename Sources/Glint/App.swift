import AppKit
import Carbon
import ServiceManagement
import SwiftUI

// MARK: - App delegate (menu bar)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        populateMenu()
        AppController.shared.statusItem = statusItem
        AppController.shared.menu = menu
        AppController.shared.setIdleStatus()

        Shortcuts.registerAll()
        NotificationCenter.default.addObserver(forName: Shortcuts.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.populateMenu() }
        }

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))

        if !Capturer.hasPermission() { CGRequestScreenCaptureAccess() }
    }

    /// Fills the status menu in place (re-run when shortcuts change so the hints stay accurate).
    private func populateMenu() {
        let m = menu!
        m.removeAllItems()
        for s in Shortcuts.all {
            let item = m.addItem(withTitle: s.title, action: #selector(runShortcut(_:)), keyEquivalent: "")
            item.representedObject = s.command
            item.target = self
            let attr = NSMutableAttributedString(string: s.title + "\t")
            attr.append(NSAttributedString(string: Shortcuts.display(for: s), attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .right, location: 240)]
            attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
            item.attributedTitle = attr
            if s.command == "capture-window" || s.command == "capture-text" { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Annotate Image…", action: #selector(annotateFile), keyEquivalent: "").target = self
        m.addItem(withTitle: "Annotate Clipboard", action: #selector(annotateClipboard), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close All Overlays", action: #selector(closeOverlays), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open Captures Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        // let the menu close before the overlay appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AppController.shared.run(command: cmd, query: [:]) }
    }

    @objc private func annotateFile() { AppController.shared.annotateFile() }
    @objc private func annotateClipboard() { AppController.shared.annotateClipboard() }
    @objc private func closeOverlays() { QuickAccess.shared.closeAll() }
    @objc private func openFolder() { NSWorkspace.shared.open(Prefs.saveFolder) }
    @objc private func openSettings() { SettingsWindow.show() }

    /// glint://capture-area, glint://open-annotate?filepath=/path.png, …
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s), let host = comps.host else { return }
        var query: [String: String] = [:]
        for q in comps.queryItems ?? [] { query[q.name] = q.value ?? "" }
        AppController.shared.run(command: host, query: query)
    }
}

// MARK: - Controller

@MainActor
final class AppController {
    static let shared = AppController()
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    private var lastAreaCG: CGRect?
    private var recorder: ScreenRecorder?
    private var recordingFrame: RecordingFrame?
    private var recordingStart: Date?
    private var recordingTimer: Timer?
    private var busy = false

    func run(command: String, query: [String: String]) {
        switch command {
        case "open-annotate":
            if let p = query["filepath"] { openEditor(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) }
            else { annotateFile() }
        case "annotate-clipboard": annotateClipboard()
        case "open-settings": SettingsWindow.show()
        case "close-overlays": QuickAccess.shared.closeAll()
        case "pin":
            if let p = query["filepath"], let (img, scale) = ImgIO.load(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) {
                PinWindow.pin(img, scale: scale)
            }
        default:
            Shortcuts.all.first { $0.command == command }?.action()
        }
    }

    // MARK: status item

    func setIdleStatus() {
        recordingTimer?.invalidate()
        let b = statusItem.button!
        b.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glint")
        b.image?.isTemplate = true
        b.title = ""
        b.contentTintColor = nil
        b.action = nil
        b.target = nil
        statusItem.menu = menu
    }

    private func setRecordingStatus() {
        statusItem.menu = nil
        let b = statusItem.button!
        b.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        b.contentTintColor = .systemRed
        b.imagePosition = .imageLeading
        b.target = self
        b.action = #selector(stopRecordingClicked)
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        recordingStart = Date()
        b.title = " 0:00"
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStart else { return }
                let s = Int(Date().timeIntervalSince(start))
                self.statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
            }
        }
    }

    @objc private func stopRecordingClicked() { toggleRecording() }

    // MARK: permission

    private func ensurePermission() -> Bool {
        if Capturer.hasPermission() { return true }
        CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "Glint needs Screen Recording permission"
        a.informativeText = "Enable Glint in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Glint."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    private func fail(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }

    // MARK: captures

    private enum Purpose { case screenshot, text, pin, record }

    private func select(_ purpose: Purpose, windowMode: Bool = false) {
        guard !busy, SelectionSession.active == nil, ensurePermission() else { return }
        busy = true
        Task {
            defer { busy = false }
            var frozen: [CGDirectDisplayID: CGImage] = [:]
            if purpose != .record {
                for s in NSScreen.screens {
                    if let img = try? await Capturer.captureDisplay(s.displayID) { frozen[s.displayID] = img }
                }
                if frozen.isEmpty { _ = ensurePermission(); return }
            }
            let hint: String = switch purpose {
            case .screenshot: "Drag to capture · Space for window · Esc to cancel"
            case .text: "Drag over text to copy it · Esc to cancel"
            case .pin: "Drag an area to pin it on screen · Esc to cancel"
            case .record: "Drag the area to record · Click for full screen · Space for window · Esc to cancel"
            }
            let session = SelectionSession(windowMode: windowMode, allowWindowMode: purpose != .text,
                                           frozen: frozen, hint: hint) { [weak self] result in
                guard let self, let result else { return }
                self.handle(result, purpose)
            }
            session.begin()
        }
    }

    private func handle(_ result: SelectionSession.Result, _ purpose: Purpose) {
        switch (result, purpose) {
        case let (.area(rect, image, screen), .screenshot):
            lastAreaCG = rect
            if let image { deliver(image, scale: scaleOf(image, rect)) } else { captureRect(rect, screen: screen) }
        case let (.window(id, rect, _, _), .screenshot):
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                do {
                    let img = try await Capturer.captureWindow(id)
                    deliver(img, scale: scaleOf(img, rect, window: true))
                } catch { fail(error) }
            }
        case let (.area(_, image, _), .text), let (.window(_, _, image, _), .text):
            if let image { recognizeText(in: image) }
        case let (.area(rect, image, _), .pin), let (.window(_, rect, image, _), .pin):
            if let image { PinWindow.pin(image, scale: scaleOf(image, rect)) }
        case let (.area(rect, _, screen), .record), let (.window(_, rect, _, screen), .record):
            startRecording(rect, screen: NSScreen.forCGRect(rect) ?? screen)
        }
    }

    private func scaleOf(_ image: CGImage, _ rect: CGRect, window: Bool = false) -> CGFloat {
        if window { return NSScreen.forCGRect(rect)?.backingScaleFactor ?? 2 }
        return max(1, (CGFloat(image.width) / max(rect.width, 1)).rounded())
    }

    func captureArea() { select(.screenshot) }
    func captureWindow() { select(.screenshot, windowMode: true) }
    func captureText() { select(.text) }
    func pinArea() { select(.pin) }

    func captureFullscreen() {
        guard ensurePermission() else { return }
        let screen = NSScreen.withMouse()
        captureRect(CGDisplayBounds(screen.displayID), screen: screen)
    }

    func capturePreviousArea() {
        guard let r = lastAreaCG else { captureArea(); return }
        guard ensurePermission() else { return }
        captureRect(r, screen: NSScreen.forCGRect(r) ?? NSScreen.withMouse())
    }

    private func captureRect(_ r: CGRect, screen: NSScreen) {
        Task {
            do {
                let img = try await Capturer.captureRect(r)
                deliver(img, scale: scaleOf(img, r))
            } catch { fail(error) }
        }
    }

    func deliver(_ image: CGImage, scale: CGFloat) {
        Sounds.playShutter()
        let capture = Capture(image: image, scale: scale, fileURL: nil)
        if Prefs.saveToDisk { capture.saveToFolder() }
        if Prefs.copyToClipboard { capture.copyToClipboard() }
        if Prefs.showQuickAccess { QuickAccess.shared.show(capture) }
        else if !Prefs.saveToDisk && !Prefs.copyToClipboard { capture.copyToClipboard() }
    }

    func recognizeText(in image: CGImage) {
        Task {
            do {
                let text = try await OCR.recognize(image)
                if text.isEmpty {
                    Toast.show("No text found", symbol: "text.viewfinder")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let lines = text.split(separator: "\n").count
                Toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text", symbol: "text.viewfinder")
            } catch { fail(error) }
        }
    }

    // MARK: recording

    func toggleRecording() {
        if let recorder {
            self.recorder = nil
            recordingFrame?.orderOut(nil)
            recordingFrame = nil
            setIdleStatus()
            Task {
                guard let url = await recorder.stop() else {
                    Toast.show("Recording failed", symbol: "exclamationmark.triangle.fill")
                    return
                }
                Sounds.playShutter()
                let thumb = await ScreenRecorder.thumbnail(for: url)
                QuickAccess.shared.show(Capture(videoURL: url, thumbnail: thumb))
            }
        } else {
            select(.record)
        }
    }

    private func startRecording(_ rect: CGRect, screen: NSScreen) {
        let r = ScreenRecorder()
        recorder = r
        let frame = RecordingFrame(cocoaRect: Geo.flip(rect))
        frame.orderFrontRegardless()
        recordingFrame = frame
        r.onStreamError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.recorder === r else { return }
                self.toggleRecording()
                self.fail(error)
            }
        }
        Task {
            do {
                try await r.start(cgRect: rect, screen: screen, showCursor: true)
                setRecordingStatus()
            } catch {
                recorder = nil
                recordingFrame?.orderOut(nil)
                recordingFrame = nil
                fail(error)
            }
        }
    }

    // MARK: editor entry points

    func annotateFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openEditor(url)
    }

    func openEditor(_ url: URL) {
        guard let (img, scale) = ImgIO.load(url) else {
            Toast.show("Couldn't open \(url.lastPathComponent)", symbol: "exclamationmark.triangle.fill")
            return
        }
        EditorWindowController.open(image: img, scale: scale, sourceURL: url)
    }

    func annotateClipboard() {
        guard let img = NSImage(pasteboard: NSPasteboard.general),
              let rep = img.representations.first,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("No image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        let scale = rep.size.width > 0 ? max(1, (CGFloat(rep.pixelsWide) / rep.size.width).rounded()) : 1
        EditorWindowController.open(image: cg, scale: scale, sourceURL: nil)
    }
}

// MARK: - Settings

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static var isOpen: Bool { window?.isVisible ?? false }

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Glint Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in
                    if EditorWindowController.hasOpenEditors == false { NSApp.setActivationPolicy(.accessory) }
                }
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @AppStorage("copyToClipboard") private var copy = true
    @AppStorage("saveToDisk") private var save = true
    @AppStorage("showQuickAccess") private var quickAccess = true
    @AppStorage("playSound") private var sound = true
    @AppStorage("quickAccessAutoClose") private var autoClose = 20
    @AppStorage("saveFolder") private var folder = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $copy)
                Toggle("Save to folder", isOn: $save)
                Toggle("Show Quick Access overlay", isOn: $quickAccess)
                Toggle("Play shutter sound", isOn: $sound)
            }
            Section("Quick Access") {
                Picker("Close automatically", selection: $autoClose) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 20 seconds").tag(20)
                    Text("After 60 seconds").tag(60)
                }
            }
            Section("Save location") {
                HStack {
                    Text((folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            ShortcutsSection()
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 720)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: folder)
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }
}
