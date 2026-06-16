// ClaudeTmuxWatcher — a menu-bar agent that flags tmux panes where a Claude
// session is waiting on you (a permission / decision prompt).
//
// Detection is content-based (the pane title cannot distinguish "waiting" from
// "busy"): a pane is WAITING when its visible content shows a numbered
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

enum PaneState { case waiting, thinking, idle }

struct ClaudePane {
    let id: String          // tmux %id, stable across scans
    let label: String       // session:win.pane
    let session: String
    let window: String      // session:window_index target
    let state: PaneState
    let summary: String     // waiting: the question line; otherwise the label
}

/// Regex: a caret-selected numbered menu item with text, e.g. "❯ 1. Yes".
let menuRegex = try! NSRegularExpression(pattern: "❯\\s*\\d+\\.\\s+\\S")
/// Regex: the spinner's elapsed/token line, e.g. "(20s · ↓ 1.2k tokens)".
let thinkingRegex = try! NSRegularExpression(pattern: "\\(\\d+.*tokens?\\)")

// Appearance. Swap the icons for any SF Symbol: "bell.fill", "hourglass",
// "exclamationmark", "bubble.left.fill", "checkmark.circle", etc.
// All emoji, so they render consistently (SF Symbols has no robot glyph).
let RobotEmoji = "🤖"
let WatcherIcon = "🔔"     // waiting: needs your answer
let ThinkingIcon = "⚙️"    // thinking: robot + gear
let IdleIcon = ""          // idle: robot only
let BadgeHeight: CGFloat = 19                                                   // pill height (bump to make bigger)
let BadgeColor = NSColor(srgbRed: 0.847, green: 0.463, blue: 0.341, alpha: 1)   // Claude terracotta #D97757
let BadgePulseColor = NSColor(srgbRed: 0.937, green: 0.624, blue: 0.494, alpha: 1) // lighter terracotta
let IdleColor = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)       // vivid green "all clear" pill
let IdleFg = NSColor.white                                                      // white check
let ThinkingColor = NSColor(srgbRed: 0.31, green: 0.51, blue: 0.85, alpha: 1)   // blue "working" pill

// Global hotkey to cycle focus through waiting panes. Default ⌃⌥⌘J; ⌃⌥⌘N cycles
// through every Claude pane. Change HotKeyCode to any kVK_ANSI_* (e.g. kVK_ANSI_K),
// and HotKeyMods to any combo of controlKey / optionKey / cmdKey / shiftKey.
let HotKeyCode = UInt32(kVK_ANSI_J)
let HotKeyMods = UInt32(controlKey | optionKey | cmdKey)
// Second hotkey: same modifiers + N cycles through *every* Claude pane, not just waiting ones.
let AllHotKeyCode = UInt32(kVK_ANSI_N)

struct ScanResult {
    var panes: [ClaudePane] = []
    var waiting: [ClaudePane] { panes.filter { $0.state == .waiting } }
    var thinking: Int { panes.filter { $0.state == .thinking }.count }
    var claude: Int { panes.count }
}

func scan() -> ScanResult {
    let fmt = "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_current_command}"
    let listing = run(TMUX, ["list-panes", "-a", "-F", fmt])
    guard !listing.isEmpty else { return ScanResult() }

    var result = ScanResult()
    for line in listing.split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5 else { continue }
        let (session, win, pane, paneId, cmd) = (f[0], f[1], f[2], f[3], f[4])
        guard cmd == "claude" else { continue }

        let content = run(TMUX, ["capture-pane", "-p", "-t", paneId])
        let state: PaneState = isWaiting(content) ? .waiting
                             : isThinking(content) ? .thinking : .idle
        result.panes.append(ClaudePane(
            id: paneId,
            label: "\(session):\(win).\(pane)",
            session: session,
            window: "\(session):\(win)",
            state: state,
            summary: state == .waiting ? summarize(content) : "\(session):\(win).\(pane)"
        ))
    }
    return result
}

func isWaiting(_ content: String) -> Bool {
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
    var lastNotified: [String: Date] = [:]   // pane id -> last banner time (drives first alert + re-nudge)
    var scanning = false                       // guard against overlapping background scans
    var lastCount = 0
    var lastThinking = 0
    var lastClaude = 0
    var pulseTimer: Timer?
    var pulseBright = false
    var waitingPanes: [ClaudePane] = []    // waiting subset, for J-cycle + notifications
    var allPanes: [ClaudePane] = []         // every Claude pane, for N-cycle + the menu
    var cycleIndex = -1
    var allCycleIndex = -1

    // Hotkey state (loaded from UserDefaults, falls back to the compile-time default).
    var hotKeyRef: EventHotKeyRef?
    var allHotKeyRef: EventHotKeyRef?
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

    /// Install the Carbon hotkey-pressed handler once; routes by hotkey id to the right cycler.
    func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData -> OSStatus in
            guard let userData = userData, let eventRef = eventRef else { return noErr }
            let app = Unmanaged<App>.fromOpaque(userData).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if hk.id == 2 { app.cycleAllClaude() } else { app.cycleNext() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }

    func unregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = allHotKeyRef { UnregisterEventHotKey(ref); allHotKeyRef = nil }
    }

    /// (Re)register both system-wide hotkeys. No Accessibility permission needed.
    func registerHotKey() {
        unregisterHotKey()
        let sig = OSType(0x4357_544B)   // 'CWTK'
        RegisterEventHotKey(currentKeyCode, currentMods,
                            EventHotKeyID(signature: sig, id: 1), GetApplicationEventTarget(), 0, &hotKeyRef)
        RegisterEventHotKey(AllHotKeyCode, HotKeyMods,
                            EventHotKeyID(signature: sig, id: 2), GetApplicationEventTarget(), 0, &allHotKeyRef)
    }

    /// Advance to the next waiting pane and switch tmux focus to it.
    func cycleNext() {
        guard !waitingPanes.isEmpty else { return }
        cycleIndex = (cycleIndex + 1) % waitingPanes.count
        focus(waitingPanes[cycleIndex])
    }

    /// Advance through every Claude pane (waiting, thinking, or idle) and focus it.
    func cycleAllClaude() {
        guard !allPanes.isEmpty else { return }
        allCycleIndex = (allCycleIndex + 1) % allPanes.count
        focus(allPanes[allCycleIndex])
    }

    // MARK: Settings

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ClaudeTmuxWatcher Settings"
            w.isReleasedWhenClosed = false
            let v = w.contentView!

            let caption = NSTextField(labelWithString: "Cycle-through-waiting shortcut:")
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

    /// Scan off the main thread (one blocking `capture-pane` per pane), then apply the
    /// result back on main. Skips if a previous scan hasn't finished.
    func tick() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scan()
            DispatchQueue.main.async {
                self?.scanning = false
                self?.apply(result)
            }
        }
    }

    func apply(_ result: ScanResult) {
        let waiting = result.waiting
        lastThinking = result.thinking
        lastClaude = result.claude
        let current = Set(waiting.map { $0.id })

        // Banner + pulse once per *new* waiting state — when a pane first enters waiting.
        // (No re-nudge; a pane that leaves and re-enters waiting notifies again.)
        var hasNew = false
        for p in waiting where lastNotified[p.id] == nil {
            notify(p)
            lastNotified[p.id] = Date()
            hasNew = true
        }
        lastNotified = lastNotified.filter { current.contains($0.key) }

        render(result.panes)
        if hasNew { startPulse() }
    }

    func render(_ panes: [ClaudePane]) {
        // Attention first: waiting, then thinking, then idle; stable within each group.
        let rank: [PaneState: Int] = [.waiting: 0, .thinking: 1, .idle: 2]
        let sorted = panes.enumerated()
            .sorted { (rank[$0.element.state]!, $0.offset) < (rank[$1.element.state]!, $1.offset) }
            .map { $0.element }

        allPanes = sorted
        waitingPanes = sorted.filter { $0.state == .waiting }
        if waitingPanes.isEmpty { cycleIndex = -1 }   // restart cycling from the top next time
        if sorted.isEmpty { allCycleIndex = -1 }
        lastCount = waitingPanes.count
        updateBadge()

        let menu = NSMenu()
        if sorted.isEmpty {
            let item = NSMenuItem(title: "No Claude panes", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for p in sorted {
                let item = NSMenuItem(title: menuTitle(p),
                                      action: #selector(switchTo(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
    }

    /// Per-pane menu row: "[session:window.pane] <message>" — the question for waiting
    /// panes, "working…" for thinking, "idle" otherwise.
    func menuTitle(_ p: ClaudePane) -> String {
        let message: String
        switch p.state {
        case .waiting:  message = p.summary
        case .thinking: message = "working…"
        case .idle:     message = "idle"
        }
        return "[\(p.label)] \(message)"
    }

    /// A rounded "pill" badge holding a sequence of `emoji number` segments
    /// (e.g. 🔔2 ⚙️1 🤖3), on a colored field. Sized to fill the menu-bar height.
    func pill(_ segments: [(emoji: String, count: Int?)], bg: NSColor, fg: NSColor) -> NSImage {
        let h = max(BadgeHeight, NSStatusBar.system.thickness)   // fill the bar
        let emojiFont = NSFont.systemFont(ofSize: round(h * 0.56))
        let numFont = NSFont.systemFont(ofSize: round(h * 0.58), weight: .bold)
        // A space rendered at 1/3 size ≈ one-third of a normal space's width.
        let thirdSpace = NSFont.systemFont(ofSize: numFont.pointSize / 3)

        // One attributed string: emoji + a 1/3 space + its number, a double space between segments.
        let s = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: numFont])) }
            s.append(NSAttributedString(string: seg.emoji, attributes: [.font: emojiFont]))
            if let c = seg.count {
                s.append(NSAttributedString(string: " ", attributes: [.font: thirdSpace]))
                s.append(NSAttributedString(string: "\(c)", attributes: [.font: numFont, .foregroundColor: fg]))
            }
        }

        let textSize = s.size()
        let padX = round(h * 0.34)
        let w = max(h, padX * 2 + ceil(textSize.width))
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            s.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                               y: (rect.height - textSize.height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Repaint just the status-bar button from `lastCount` + current pulse state.
    func updateBadge() {
        guard let button = status.button else { return }
        button.attributedTitle = NSAttributedString(string: "")

        // 🤖 total Claude panes always leads; then 🔔 waiting, ⚙️ thinking when non-zero.
        var segs: [(emoji: String, count: Int?)] = [(RobotEmoji, lastClaude)]
        if lastCount > 0    { segs.append((WatcherIcon, lastCount)) }
        if lastThinking > 0 { segs.append((ThinkingIcon, lastThinking)) }

        // Background follows the highest-priority active state; terracotta pulses when a pane starts waiting.
        let bg = lastCount > 0    ? (pulseBright ? BadgePulseColor : BadgeColor)
               : lastThinking > 0 ? ThinkingColor
               :                    IdleColor
        button.image = pill(segs, bg: bg, fg: .white)
    }

    /// Flash the badge between red and orange for ~1.5s when a pane starts waiting.
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

    func notify(_ p: ClaudePane) {
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
    func switchCommand(_ p: ClaudePane) -> String {
        "\(TMUX) switch-client -t '\(p.session)' ; "
        + "\(TMUX) select-window -t '\(p.window)' ; "
        + "\(TMUX) select-pane -t '\(p.id)'"
    }

    /// Switch tmux focus to the pane, then raise the GUI terminal hosting it —
    /// tmux focus alone is invisible if the terminal window is behind other apps.
    func focus(_ p: ClaudePane) {
        run("/bin/sh", ["-c", switchCommand(p)])
        activateTerminalApp(for: p.session)
    }

    /// Walk from the tmux client's process up the parent chain to the hosting `.app`
    /// bundle and bring it forward. Best-effort: silently no-ops if nothing matches.
    func activateTerminalApp(for session: String) {
        let pidStr = run(TMUX, ["list-clients", "-t", session, "-F", "#{client_pid}"])
            .split(separator: "\n").first.map(String.init) ?? ""
        guard var pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) else { return }
        for _ in 0..<16 {
            let line = run("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sp = line.firstIndex(of: " ") else { return }
            let ppid = Int32(String(line[..<sp])) ?? -1
            let comm = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            if comm.contains(".app/Contents/MacOS/") {
                NSRunningApplication(processIdentifier: pid)?.activate()
                return
            }
            if ppid <= 1 { return }
            pid = ppid
        }
    }

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? ClaudePane else { return }
        focus(p)
    }

    @objc func refresh() { tick() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = App()
app.delegate = delegate
app.run()
