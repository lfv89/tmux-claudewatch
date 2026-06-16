#!/bin/bash
# An fzf picker of every Claude session with its state — the macOS app's dropdown, inside
# tmux. Bound to `prefix t` by the plugin; meant to run in a `display-popup -E`. Pick a row
# to jump to that pane. Rows are sorted waiting → thinking → idle, like the menu-bar app.
set -euo pipefail

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "#[align=absolute-centre]claudewatch: fzf is required for the prefix-t popup"
  exit 0
fi

# One row per Claude pane, tab-separated:  rank \t pane_id \t session \t window \t display
rows() {
  while IFS=$'\t' read -r s w pi p cmd; do
    [ "$cmd" = "claude" ] || continue
    c=$(tmux capture-pane -p -t "$p" 2>/dev/null) || c=""
    if printf '%s' "$c" | grep -q 'Esc to cancel' \
       && printf '%s' "$c" | grep -qE '❯[[:space:]]*[0-9]+\.[[:space:]]+[^[:space:]]'; then
      rank=0; icon="🔔"
      detail=$(printf '%s\n' "$c" | sed 's/[[:space:]]*$//' \
                 | grep -E '^(Do you want|Would you like)|\?$' | tail -1 | sed 's/^[[:space:]]*//')
      [ -z "$detail" ] && detail="needs a decision"
    elif printf '%s' "$c" | grep -qiE 'esc to interrupt|\([0-9].*tokens?\)'; then
      rank=1; icon="⚙️"; detail="working…"
    else
      rank=2; icon="🤖"; detail=""
    fi
    printf '%d\t%s\t%s\t%s\t%s %s:%s.%s  %s\n' "$rank" "$p" "$s" "$w" "$icon" "$s" "$w" "$pi" "$detail"
  done < <(tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_index}	#{pane_id}	#{pane_current_command}')
}

lines=$(rows | sort -t"$(printf '\t')" -k1,1n)
if [ -z "$lines" ]; then
  tmux display-message "#[align=absolute-centre]there are no Claude sessions"
  exit 0
fi

sel=$(printf '%s\n' "$lines" | fzf --delimiter="$(printf '\t')" --with-nth=5 --reverse --no-info \
        --color="bg:#2E3440,fg:#D8DEE9,hl:#88C0D0,bg+:#3B4252,fg+:#ECEFF4,hl+:#5E81AC,pointer:#EBCB8B") || exit 0
[ -z "$sel" ] && exit 0

pid=$(printf '%s' "$sel" | cut -f2)
sess=$(printf '%s' "$sel" | cut -f3)
win=$(printf '%s' "$sel" | cut -f4)
tmux switch-client -t "$sess" 2>/dev/null || true
tmux select-window -t "$sess:$win"
tmux select-pane -t "$pid"
