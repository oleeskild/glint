import AppKit
import Carbon
import SwiftUI

// MARK: - Key combos

struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var mods: Int // Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey)

    static let disabled = KeyCombo(keyCode: -1, mods: 0)
    var isDisabled: Bool { keyCode < 0 }

    init(keyCode: Int, mods: Int) {
        self.keyCode = keyCode
        self.mods = mods
    }

    init(event: NSEvent) {
        keyCode = Int(event.keyCode)
        mods = KeyCombo.carbonMods(event.modifierFlags)
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return m
    }

    static func modSymbols(_ m: Int) -> String {
        var s = ""
        if m & controlKey != 0 { s += "⌃" }
        if m & optionKey != 0 { s += "⌥" }
        if m & shiftKey != 0 { s += "⇧" }
        if m & cmdKey != 0 { s += "⌘" }
        return s
    }

    var display: String { isDisabled ? "" : KeyCombo.modSymbols(mods) + KeyCombo.keyName(keyCode) }

    var isFunctionKey: Bool { KeyCombo.functionKeys.keys.contains(keyCode) }

    /// Needs ⌘, ⌥ or ⌃ (Shift alone would swallow normal typing), unless it's an F-key.
    var isValidGlobal: Bool { isFunctionKey || mods & (cmdKey | optionKey | controlKey) != 0 }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    /// Name of the key in the user's current keyboard layout (so a Norwegian layout shows Ø, not ;).
    static func keyName(_ code: Int) -> String {
        if let f = functionKeys[code] { return f }
        if let s = specialKeys[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

// MARK: - Shortcut table

struct Shortcut {
    let title: String
    let command: String
    let defaultCombo: KeyCombo
    let action: @MainActor () -> Void
}

@MainActor
enum Shortcuts {
    static let changed = Notification.Name("GlintShortcutsChanged")
    private static let defaultMods = optionKey | shiftKey

    static var all: [Shortcut] {
        let c = AppController.shared
        func s(_ title: String, _ key: Int, _ cmd: String, _ action: @escaping @MainActor () -> Void) -> Shortcut {
            Shortcut(title: title, command: cmd, defaultCombo: KeyCombo(keyCode: key, mods: defaultMods), action: action)
        }
        return [
            s("Capture Area", kVK_ANSI_1, "capture-area") { c.captureArea() },
            s("Capture Previous Area", kVK_ANSI_2, "capture-previous-area") { c.capturePreviousArea() },
            s("Capture Fullscreen", kVK_ANSI_3, "capture-fullscreen") { c.captureFullscreen() },
            s("Capture Window", kVK_ANSI_4, "capture-window") { c.captureWindow() },
            s("Record Screen", kVK_ANSI_5, "record-screen") { c.toggleRecording() },
            s("Capture Text (OCR)", kVK_ANSI_6, "capture-text") { c.captureText() },
            s("Pin Area to Screen", kVK_ANSI_7, "pin-area") { c.pinArea() },
        ]
    }

    private static func key(_ cmd: String) -> String { "shortcut.\(cmd)" }

    /// The combo currently assigned to a command (`.disabled` if the user cleared it).
    static func combo(for s: Shortcut) -> KeyCombo {
        guard let data = UserDefaults.standard.data(forKey: key(s.command)),
              let c = try? JSONDecoder().decode(KeyCombo.self, from: data) else { return s.defaultCombo }
        return c
    }

    static func display(for s: Shortcut) -> String { combo(for: s).display }

    /// Assigns a combo; any other Glint command already using it is cleared. Returns the title of that command.
    @discardableResult
    static func set(_ combo: KeyCombo, for command: String) -> String? {
        var stolenFrom: String?
        if !combo.isDisabled {
            for other in all where other.command != command && Self.combo(for: other) == combo {
                store(.disabled, other.command)
                stolenFrom = other.title
            }
        }
        store(combo, command)
        NotificationCenter.default.post(name: changed, object: nil)
        return stolenFrom
    }

    static func resetAll() {
        for s in all { UserDefaults.standard.removeObject(forKey: key(s.command)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func store(_ c: KeyCombo, _ cmd: String) {
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: key(cmd)) }
    }

    /// (Re)registers every global hotkey. Returns the titles of shortcuts macOS refused.
    @discardableResult
    static func registerAll() -> [String] {
        HotKeys.shared.unregisterAll()
        var failed: [String] = []
        for s in all {
            let c = combo(for: s)
            guard !c.isDisabled else { continue }
            if !HotKeys.shared.register(keyCode: c.keyCode, modifiers: c.mods, s.action) { failed.append(s.title) }
        }
        return failed
    }

    /// While a recorder field is listening, global hotkeys are paused so the combo reaches the field.
    static func suspend() { HotKeys.shared.unregisterAll() }
    static func resume() { registerAll() }
}

// MARK: - Recorder control

final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo = .disabled { didSet { refresh() } }
    var onChange: ((KeyCombo) -> Void)?
    private var recording = false { didSet { refresh() } }
    private var liveMods = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        font = .systemFont(ofSize: 13, weight: .medium)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

    private func refresh() {
        if recording {
            title = liveMods == 0 ? "Type shortcut…" : KeyCombo.modSymbols(liveMods) + "…"
            contentTintColor = .controlAccentColor
        } else {
            title = combo.isDisabled ? "Click to record" : combo.display
            contentTintColor = combo.isDisabled ? .secondaryLabelColor : nil
        }
        toolTip = recording ? "Press a key combination. Esc cancels, Delete clears." : "Click to change"
    }

    @objc private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        // Only one recorder listens at a time.
        if let other = ShortcutRecorderButton.active, other !== self { other.stop() }
        ShortcutRecorderButton.active = self
        liveMods = 0
        recording = true
        window?.makeFirstResponder(self)
        Task { @MainActor in Shortcuts.suspend() }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if ShortcutRecorderButton.active === self { ShortcutRecorderButton.active = nil }
        Task { @MainActor in Shortcuts.resume() }
    }

    private static weak var active: ShortcutRecorderButton?

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return super.flagsChanged(with: event) }
        liveMods = KeyCombo.carbonMods(event.modifierFlags)
        refresh()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let c = KeyCombo(event: event)
        if c.mods == 0 && event.keyCode == UInt16(kVK_Escape) { stop(); return }
        if c.mods == 0 && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            combo = .disabled
            onChange?(.disabled)
            stop()
            return
        }
        guard c.isValidGlobal else { NSSound.beep(); return }
        combo = c
        onChange?(c)
        stop()
    }
}

struct ShortcutField: NSViewRepresentable {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let b = ShortcutRecorderButton(frame: .zero)
        b.combo = combo
        b.onChange = onChange
        return b
    }

    func updateNSView(_ b: ShortcutRecorderButton, context: Context) {
        if b.combo != combo { b.combo = combo }
        b.onChange = onChange
    }
}

/// Settings section listing every shortcut with a recorder.
struct ShortcutsSection: View {
    @State private var version = 0
    @State private var message: String?

    var body: some View {
        Section {
            ForEach(Shortcuts.all, id: \.command) { s in
                LabeledContent(s.title) {
                    HStack(spacing: 6) {
                        ShortcutField(combo: Shortcuts.combo(for: s)) { c in
                            let stolen = Shortcuts.set(c, for: s.command)
                            let failed = Shortcuts.registerAll()
                            if failed.contains(s.title) {
                                message = "\(c.display) is reserved by macOS or another app, so it may not work."
                            } else if let stolen {
                                message = "\(c.display) was moved from “\(stolen)”, which now has no shortcut."
                            } else {
                                message = nil
                            }
                            version += 1
                        }
                        .frame(width: 140)
                        Button {
                            Shortcuts.set(.disabled, for: s.command)
                            Shortcuts.registerAll()
                            message = nil
                            version += 1
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                            .help("Remove shortcut")
                            .opacity(Shortcuts.combo(for: s).isDisabled ? 0 : 1)
                    }
                }
            }
            .id(version)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Restore Defaults") {
                    Shortcuts.resetAll()
                    Shortcuts.registerAll()
                    message = nil
                    version += 1
                }
                Spacer()
            }
            Text("To use ⇧⌘3, ⇧⌘4 or ⇧⌘5, first turn off the built-in ones in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Also scriptable: open \"glint://capture-area\", glint://open-annotate?filepath=…, glint://pin?filepath=…")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
