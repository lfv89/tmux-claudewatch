# tmux-claudewatch

See, at a glance, which **Claude Code sessions across your tmux panes need you** — and jump
straight to them.

A pane is **waiting** when Claude is sitting on a permission / decision prompt
(`Do you want to make this edit…? ❯ 1. Yes / 2. … / 3. No`), **thinking** when it's actively
working (spinner/token line), or **idle** otherwise.

The repo ships two independent pieces:

| | What | Needs |
|---|---|---|
| **tmux plugin** (baseline) | A status-bar segment with live counts (󰚩 total · 󰒓 thinking · 󰂚 waiting) and keys to jump between Claude panes. | just tmux |
| **macOS menu-bar app** (optional) | A menu-bar pill + notifications that alert you when a pane *enters* the waiting state, even when tmux isn't on screen. | macOS (prebuilt; no toolchain) |

Detection is content-based (`tmux capture-pane`): a numbered selection menu (`❯ 1. …`) plus the
footer `Esc to cancel` means waiting; `esc to interrupt` / a `(… tokens)` line means thinking. No
Claude or tmux hooks required.

---

## tmux plugin

### Install (TPM)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'lfv89/tmux-claudewatch'
```

Put the status token wherever you want the segment to appear:

```tmux
set -g status-right "#{claudewatch} %H:%M"
```

Then hit `prefix + I` to fetch the plugin.

### What you get

- **Status segment** — `#{claudewatch}` expands to `󰚩 <total> 󰒓 <thinking> 󰂚 <waiting>`. Prints
  nothing when no Claude panes are running.
- **Keys** (unbound by default — bind them via the options below):
  - cycle through **every** Claude pane (any state)
  - cycle through **waiting** panes only
  - **fzf popup** listing every Claude session with its state; pick one to jump
    (the macOS dropdown, inside tmux — needs `fzf`)
- **Pane-border tag** — each Claude pane gets a `@claude_waiting` option (`1` when waiting, else
  `0`), so you can restyle the active pane's border, e.g.:

  ```tmux
  set -g pane-border-status top
  set -g pane-border-format "#{?#{==:#{@claude_waiting},1},#[bg=red] waiting ,#{pane_current_command}}"
  ```

### Options

| Option | Default | Meaning |
|---|---|---|
| `@claudewatch_format` | `#(…/scripts/claude-count.sh)` | Override the status segment command. |
| `@claudewatch_jump_key` | _(unset)_ | Key (under prefix) to cycle all Claude panes. Unset = unbound. |
| `@claudewatch_jump_waiting_key` | _(unset)_ | Key (under prefix) to cycle waiting panes. Unset = unbound. |
| `@claudewatch_menu_key` | _(unset)_ | Key (under prefix) to open the fzf popup picker. Unset = unbound. |

The keys are **unbound by default** — set the options to bind them, e.g.:

```tmux
set -g @claudewatch_jump_waiting_key 'n'  # note: overrides tmux's default next-window
set -g @claudewatch_jump_key 'N'
set -g @claudewatch_menu_key 't'
```

---

## macOS menu-bar app (optional)

The plugin already surfaces everything inside tmux. Install this only if you also want a
**menu-bar pill** and **notification banners** that reach you when tmux isn't visible.

```sh
curl -fsSL https://raw.githubusercontent.com/lfv89/tmux-claudewatch/main/macos/install.sh | sh
```

This downloads a prebuilt app (no clone or Swift toolchain needed), installs it to
`~/Library/Application Support/claudewatch`, and registers a LaunchAgent (starts at login).
Re-run after updates. The download is unsigned, so the installer clears the Gatekeeper
quarantine itself — read the script first if that gives you pause.

If you have a checkout already, `~/.tmux/plugins/tmux-claudewatch/macos/install.sh` works too,
and falls back to building from source (needs `xcode-select --install`) when no release is available.

- **Menu-bar pill** — `🤖<total>` always, plus `🔔<waiting>` / `⚙️<thinking>` when non-zero. The
  dropdown lists every Claude pane; click one to jump (and raise the terminal).
- **Notifications** — fire once when a pane **enters the waiting state**, showing the prompt
  question; clicking the banner jumps to the pane. Needs `terminal-notifier`
  (`brew install terminal-notifier`).
- **Global hotkeys** — `⌃⌥⌘J` next waiting pane, `⌃⌥⌘N` next Claude pane (any state). Change the
  codes near the top of `macos/ClaudeTmuxWatcher.swift`.

Uninstall:

```sh
launchctl bootout gui/$(id -u)/works.vlabs.tmuxclaudewatcher
rm ~/Library/LaunchAgents/works.vlabs.tmuxclaudewatcher.plist
rm -rf ~/Library/Application\ Support/claudewatch
```

Logs: `/tmp/tmuxclaudewatcher.log`.

---

## Notes / limits

- The waiting/thinking signatures are tuned to current Claude Code dialogs. If a future TUI variant
  drops `Esc to cancel`, adjust `isWaiting()` in `macos/ClaudeTmuxWatcher.swift` and the matching
  `grep` in `scripts/claude-count.sh` / `scripts/next-waiting.sh`.
- The macOS app installs from a prebuilt release — no toolchain needed. The Swift toolchain
  (`xcode-select --install`) is only required for the source-build fallback when running the
  installer from a checkout with no release available.
