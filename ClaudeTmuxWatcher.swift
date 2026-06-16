// ClaudeTmuxWatcher — a menu-bar agent that flags tmux panes where a Claude
// session is blocked on you (a permission / decision prompt).
//
// Detection is content-based (the pane title cannot distinguish "blocked" from
// "busy"): a pane is BLOCKED when its visible content shows a numbered
// selection menu (`❯ 1. …`) together with the dialog footer `Esc to cancel`.
// The idle `❯ ` prompt and the working spinner are deliberately ignored.

import AppKit
import Carbon.HIToolbox

// MARK: - Shell helpers

/// First existing path wins; falls back to bare name (resolved via PATH).
func resolve(_ name: String, _ candidates: [String]) -> String {
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return name
}
let TMUX = resolve("tmux", ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
let NOTIFIER = resolve("terminal-notifier",
                       ["/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"])

/// Run a command, return stdout (empty string on any failure). Synchronous.
@discardableResult
func run(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Detection

struct BlockedPane {
    let id: String          // tmux %id, stable across scans
    let label: String       // session:win.pane
    let session: String
    let window: String      // session:window_index target
    let summary: String     // the question line
}

/// Regex: a caret-selected numbered menu item with text, e.g. "❯ 1. Yes".
let menuRegex = try! NSRegularExpression(pattern: "❯\\s*\\d+\\.\\s+\\S")
/// Regex: the spinner's elapsed/token line, e.g. "(20s · ↓ 1.2k tokens)".
let thinkingRegex = try! NSRegularExpression(pattern: "\\(\\d+.*tokens?\\)")

// Appearance. Swap the icons for any SF Symbol: "bell.fill", "hourglass",
// "exclamationmark", "bubble.left.fill", "checkmark.circle", etc.
// All emoji, so they render consistently (SF Symbols has no robot glyph).
let RobotEmoji = "🤖"
let WatcherIcon = "🔔"     // blocked: robot + bell
let ThinkingIcon = "⚙️"    // thinking: robot + gear
let IdleIcon = ""          // idle: robot only
let BadgeHeight: CGFloat = 19                                                   // pill height (bump to make bigger)
let BadgeColor = NSColor(srgbRed: 0.847, green: 0.463, blue: 0.341, alpha: 1)   // Claude terracotta #D97757
let BadgePulseColor = NSColor(srgbRed: 0.937, green: 0.624, blue: 0.494, alpha: 1) // lighter terracotta
let IdleColor = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)       // vivid green "all clear" pill
let IdleFg = NSColor.white                                                      // white check
let ThinkingColor = NSColor(srgbRed: 0.31, green: 0.51, blue: 0.85, alpha: 1)   // blue "working" pill

// Global hotkey to cycle focus through blocked panes. Default ⌃⌥⌘J.
// Change HotKeyCode to any kVK_ANSI_* (e.g. kVK_ANSI_K), and HotKeyMods to any
// combo of controlKey / optionKey / cmdKey / shiftKey.
let HotKeyCode = UInt32(kVK_ANSI_J)
let HotKeyMods = UInt32(controlKey | optionKey | cmdKey)

struct ScanResult {
    var blocked: [BlockedPane] = []
    var thinking = 0   // panes actively processing (not blocked)
}

func scan() -> ScanResult {
    let fmt = "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}"
    let listing = run(TMUX, ["list-panes", "-a", "-F", fmt])
    guard !listing.isEmpty else { return ScanResult() }

    var result = ScanResult()
    for line in listing.split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4 else { continue }
        let (session, win, pane, paneId) = (f[0], f[1], f[2], f[3])

        let content = run(TMUX, ["capture-pane", "-p", "-t", paneId])
        if isBlocked(content) {
            result.blocked.append(BlockedPane(
                id: paneId,
                label: "\(session):\(win).\(pane)",
                session: session,
                window: "\(session):\(win)",
                summary: summarize(content)
            ))
        } else if isThinking(content) {
            result.thinking += 1
        }
    }
    return result
}

func isBlocked(_ content: String) -> Bool {
    guard content.contains("Esc to cancel") else { return false }
    let range = NSRange(content.startIndex..., in: content)
    return menuRegex.firstMatch(in: content, range: range) != nil
}

/// Actively processing: the spinner shows a token/timer line or "esc to interrupt".
func isThinking(_ content: String) -> Bool {
    let lower = content.lowercased()
    if lower.contains("esc to interrupt") { return true }
    let range = NSRange(content.startIndex..., in: content)
    return thinkingRegex.firstMatch(in: content, range: range) != nil
}

/// Best-effort one-liner: the prompt question above the menu.
func summarize(_ content: String) -> String {
    let lines = content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    if let q = lines.last(where: {
        $0.hasPrefix("Do you want") || $0.hasPrefix("Would you like") || $0.hasSuffix("?")
    }) { return q }
    return "needs a decision"
}

// MARK: - App

class App: NSObject, NSApplicationDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var notified = Set<String>()   // pane ids we've already alerted on (this block)
    var lastCount = 0
    var lastThinking = 0
    var pulseTimer: Timer?
    var pulseBright = false
    var blockedPanes: [BlockedPane] = []   // current blocked set, for cycling
    var cycleIndex = -1

    // Hotkey state (loaded from UserDefaults, falls back to the compile-time default).
    var hotKeyRef: EventHotKeyRef?
    var handlerInstalled = false
    var currentKeyCode = HotKeyCode
    var currentMods = HotKeyMods
    var hotKeyLabel = "⌃⌥⌘J"

    // Settings window.
    var settingsWindow: NSWindow?
    var shortcutLabel: NSTextField!
    var recordButton: NSButton!
    var recordMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        status.menu = NSMenu()
        render([])
        loadHotKey()
        installHotKeyHandler()
        registerHotKey()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    // MARK: Hotkey

    func loadHotKey() {
        let d = UserDefaults.standard
        if d.object(forKey: "hotKeyCode") != nil {
            currentKeyCode = UInt32(d.integer(forKey: "hotKeyCode"))
            currentMods = UInt32(d.integer(forKey: "hotKeyMods"))
            hotKeyLabel = d.string(forKey: "hotKeyLabel") ?? hotKeyLabel
        }
    }

    /// Install the Carbon hotkey-pressed handler once; it routes to cycleNext().
    func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            let app = Unmanaged<App>.fromOpaque(userData!).takeUnretainedValue()
            app.cycleNext()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }

    func unregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    /// (Re)register the system-wide hotkey from current state. No Accessibility permission needed.
    func registerHotKey() {
        unregisterHotKey()
        let id = EventHotKeyID(signature: OSType(0x4357_544B), id: 1)   // 'CWTK'
        RegisterEventHotKey(currentKeyCode, currentMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Advance to the next blocked pane and switch tmux focus to it.
    func cycleNext() {
        guard !blockedPanes.isEmpty else { return }
        cycleIndex = (cycleIndex + 1) % blockedPanes.count
        run("/bin/sh", ["-c", switchCommand(blockedPanes[cycleIndex])])
    }

    // MARK: Settings

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ClaudeTmuxWatcher Settings"
            w.isReleasedWhenClosed = false
            let v = w.contentView!

            let caption = NSTextField(labelWithString: "Cycle-through-blockers shortcut:")
            caption.frame = NSRect(x: 20, y: 108, width: 320, height: 18)
            v.addSubview(caption)

            shortcutLabel = NSTextField(labelWithString: hotKeyLabel)
            shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold)
            shortcutLabel.frame = NSRect(x: 20, y: 62, width: 320, height: 32)
            v.addSubview(shortcutLabel)

            recordButton = NSButton(title: "Record Shortcut", target: self,
                                    action: #selector(toggleRecord))
            recordButton.bezelStyle = .rounded
            recordButton.frame = NSRect(x: 16, y: 16, width: 180, height: 32)
            v.addSubview(recordButton)

            settingsWindow = w
        }
        shortcutLabel.stringValue = hotKeyLabel
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleRecord() {
        if recordMonitor != nil { stopRecording(restore: true); return }
        unregisterHotKey()   // don't let the live hotkey fire while recording
        recordButton.title = "Press keys… (Esc to cancel)"
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.stopRecording(restore: true); return nil }
            self.captureShortcut(e)
            return nil   // swallow the key while recording
        }
    }

    /// Turn a keyDown into a hotkey, persist it, and re-register. Ignores modifier-only presses.
    func captureShortcut(_ e: NSEvent) {
        let flags = e.modifierFlags
        var mods: UInt32 = 0
        var label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option)  { mods |= UInt32(optionKey);  label += "⌥" }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey);   label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey);     label += "⌘" }
        guard mods != 0 else { return }   // require at least one modifier

        currentKeyCode = UInt32(e.keyCode)
        currentMods = mods
        hotKeyLabel = label + (e.charactersIgnoringModifiers ?? "?").uppercased()

        let d = UserDefaults.standard
        d.set(Int(currentKeyCode), forKey: "hotKeyCode")
        d.set(Int(currentMods), forKey: "hotKeyMods")
        d.set(hotKeyLabel, forKey: "hotKeyLabel")

        registerHotKey()
        shortcutLabel?.stringValue = hotKeyLabel
        stopRecording(restore: false)
    }

    func stopRecording(restore: Bool) {
        if let m = recordMonitor { NSEvent.removeMonitor(m); recordMonitor = nil }
        recordButton?.title = "Record Shortcut"
        if restore { registerHotKey() }   // re-arm the unchanged hotkey after a cancel
    }

    func tick() {
        let result = scan()
        let blocked = result.blocked
        lastThinking = result.thinking

        // Fire a banner (and a visual pulse) on each fresh not-blocked -> blocked transition.
        let current = Set(blocked.map { $0.id })
        var hasNew = false
        for p in blocked where !notified.contains(p.id) {
            notify(p)
            hasNew = true
        }
        notified = current   // drop cleared panes so they can re-notify later

        render(blocked)
        if hasNew { startPulse() }
    }

    func render(_ blocked: [BlockedPane]) {
        blockedPanes = blocked
        if blocked.isEmpty { cycleIndex = -1 }   // restart cycling from the top next time
        lastCount = blocked.count
        updateBadge()

        let menu = NSMenu()
        if blocked.isEmpty {
            let item = NSMenuItem(title: "No Claude panes waiting", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for p in blocked {
                let item = NSMenuItem(title: "⚠ \(p.summary)",
                                      action: #selector(switchTo(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
    }

    /// A rounded "pill" badge: robot + state emoji (bell/check), optionally followed by a
    /// count, on a colored field. Sized to fill the menu-bar height.
    func pill(symbol: String, count: Int?, bg: NSColor, fg: NSColor) -> NSImage {
        let h = max(BadgeHeight, NSStatusBar.system.thickness)   // fill the bar

        // Robot + state, both emoji so they render consistently.
        let icons = "\(RobotEmoji)\(symbol)" as NSString
        let iconAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: round(h * 0.56))]
        let iconSize = icons.size(withAttributes: iconAttrs)

        let text: NSString? = count.map { "\($0)" as NSString }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: round(h * 0.58), weight: .bold),
            .foregroundColor: fg,
        ]
        let textSize = text?.size(withAttributes: attrs) ?? .zero

        let padX = round(h * 0.3), gap = round(h * 0.18)
        let contentW = iconSize.width + (text != nil ? gap + textSize.width : 0)
        let w = max(h, padX * 2 + contentW)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            let startX = (rect.width - contentW) / 2
            icons.draw(at: NSPoint(x: startX, y: (rect.height - iconSize.height) / 2),
                       withAttributes: iconAttrs)
            if let text = text {
                text.draw(at: NSPoint(x: startX + iconSize.width + gap,
                                      y: (rect.height - textSize.height) / 2),
                          withAttributes: attrs)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Repaint just the status-bar button from `lastCount` + current pulse state.
    func updateBadge() {
        guard let button = status.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        if lastCount > 0 {
            // Blocked takes priority: robot + bell, terracotta (pulses on new).
            button.image = pill(symbol: WatcherIcon, count: nil,
                                bg: pulseBright ? BadgePulseColor : BadgeColor, fg: .white)
        } else if lastThinking > 0 {
            // Thinking: robot + gear, blue.
            button.image = pill(symbol: ThinkingIcon, count: nil, bg: ThinkingColor, fg: .white)
        } else {
            // Idle "all clear": robot only, green.
            button.image = pill(symbol: IdleIcon, count: nil, bg: IdleColor, fg: IdleFg)
        }
    }

    /// Flash the badge between red and orange for ~1.5s on a new block.
    func startPulse() {
        pulseTimer?.invalidate()
        var ticks = 0
        pulseBright = true
        updateBadge()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.pulseBright.toggle()
            self.updateBadge()
            ticks += 1
            if ticks >= 6 {
                t.invalidate()
                self.pulseBright = false
                self.updateBadge()
            }
        }
    }

    func notify(_ p: BlockedPane) {
        guard FileManager.default.isExecutableFile(atPath: NOTIFIER) else { return }
        run(NOTIFIER, [
            "-title", "Claude needs you",
            "-subtitle", p.label,
            "-message", p.summary,
            "-group", "claudy-\(p.id)",
            "-execute", switchCommand(p),
        ])
    }

    /// Shell command that focuses the pane within tmux.
    func switchCommand(_ p: BlockedPane) -> String {
        "\(TMUX) switch-client -t '\(p.session)' ; "
        + "\(TMUX) select-window -t '\(p.window)' ; "
        + "\(TMUX) select-pane -t '\(p.id)'"
    }

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? BlockedPane else { return }
        run("/bin/sh", ["-c", switchCommand(p)])
    }

    @objc func refresh() { tick() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = App()
app.delegate = delegate
app.run()
