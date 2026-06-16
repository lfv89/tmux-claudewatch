# ClaudeTmuxWatcher

A tiny macOS menu-bar agent that tells you when a **Claude session in a tmux pane is blocked
waiting on you** — i.e. sitting on a permission / decision prompt
(`Do you want to make this edit…? ❯ 1. Yes / 2. … / 3. No`).

- **Menu-bar icon** shows a count of currently-blocked panes; the dropdown lists each one with its
  question. Click a row to switch tmux focus to that pane.
- **Notification banner** fires once each time a pane *enters* the blocked state (via
  `terminal-notifier`); clicking the banner also switches to the pane.

It is *blocked-only* by design: panes that are actively working (spinner) or idle at an empty
`❯` prompt are not flagged.

## How detection works

Pane titles can't tell "blocked" from "busy" (both show `✳`), so detection reads pane **content**:
a pane is blocked when `tmux capture-pane` shows a numbered selection menu (`❯ 1. …`) together with
the dialog footer `Esc to cancel`. Polled every 2s. No tmux/Claude config or hooks required — it
works for any pane.

## Requirements

- `tmux`, `terminal-notifier` (`brew install terminal-notifier`), and the Swift toolchain (Xcode
  command-line tools) for building.

## Build

```sh
./build.sh          # -> ./ClaudeTmuxWatcher
./build.sh --app    # also -> ./ClaudeTmuxWatcher.app (for Login Items, if you prefer)
```

## Run

Foreground (for a quick try):

```sh
./ClaudeTmuxWatcher
```

Quit from the menu-bar dropdown.

## Run at login (LaunchAgent)

`build.sh` generates `works.vlabs.tmuxclaudewatcher.plist` with this checkout's absolute path baked
in (launchd needs a literal path — it won't expand `~`/`$HOME`):

```sh
./build.sh
cp works.vlabs.tmuxclaudewatcher.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/works.vlabs.tmuxclaudewatcher.plist
```

Stop / remove:

```sh
launchctl unload -w ~/Library/LaunchAgents/works.vlabs.tmuxclaudewatcher.plist
```

Logs go to `/tmp/tmuxclaudewatcher.log`. If you move this directory, re-run `./build.sh` and copy the
regenerated plist.

## Cycling through blocked panes

- **Global hotkeys** (from anywhere): **⌃⌥⌘J** jumps to the next *blocked* pane; **⌃⌥⌘N** cycles
  through *every* Claude pane. Change the codes/modifiers near the top of `ClaudeTmuxWatcher.swift`.
- **Inside tmux**: `tmux-next-blocked.sh` does the same, jumping to the next blocked pane *after*
  your current one. Bind it (this **overrides the default `prefix n` = next-window**):

  ```tmux
  # ~/.tmux.conf
  bind n run-shell '/path/to/tmux-claudewatch/tmux-next-blocked.sh'
  ```

  Reload with `tmux source-file ~/.tmux.conf`. To revert to the default: `bind n next-window`
  (or pick a different key, e.g. `bind C-n run-shell '…'`).

## Notes / limits

- First run, macOS may ask to grant **Notifications** permission to `terminal-notifier`.
- Clicking a pane switches tmux's focus (`switch-client` / `select-window` / `select-pane`); it does
  not raise your terminal's GUI window.
- The blocked signature is tuned to current Claude Code permission and question dialogs. If a future
  dialog variant drops `Esc to cancel`, adjust `isBlocked()` in `ClaudeTmuxWatcher.swift`.
