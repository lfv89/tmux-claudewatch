#!/bin/bash
# prefix-t popup: an fzf picker of every Claude session with a live preview of the
# selected pane — the macOS dropdown, inside tmux. Bound via `run-shell -b` so the
# interactive popup never blocks the tmux server. The outer pass builds the rows and
# sizes the popup to fit; it then re-execs this same script inside the popup
# (CW_POPUP=1) to run fzf and jump to the chosen pane.
set -euo pipefail

FZF_COLORS="bg:#2E3440,fg:#D8DEE9,hl:#88C0D0,bg+:#3B4252,fg+:#ECEFF4,hl+:#5E81AC,pointer:#EBCB8B,border:#4C566A,label:#88C0D0"

# ---------- inside the popup: pick + jump ----------
if [ "${CW_POPUP:-}" = "1" ]; then
  trap 'rm -f "$CW_ROWS"' EXIT
  sel=$(fzf --ansi --delimiter=$'\t' --with-nth=5 \
            --layout=reverse-list --border=rounded \
            --padding=1 --prompt='  ' --pointer='▶' --marker='▏' \
            --info=hidden --no-separator --no-scrollbar \
            --preview 'tmux capture-pane -ep -t {2}' \
            --preview-window='right,55%,border-left' \
            --color="$FZF_COLORS" < "$CW_ROWS") || exit 0
  [ -z "$sel" ] && exit 0
  pid=$(printf '%s' "$sel" | cut -f2)
  sess=$(printf '%s' "$sel" | cut -f3)
  win=$(printf '%s' "$sel" | cut -f4)
  tmux switch-client -t "$sess" 2>/dev/null || true
  tmux select-window -t "$sess:$win"
  tmux select-pane -t "$pid"
  exit 0
fi

# ---------- outside: build rows, size the popup, open it ----------
command -v fzf >/dev/null 2>&1 || {
  tmux display-message "#[align=absolute-centre]claudewatch: fzf is required for the prefix-t popup"
  exit 0
}

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

rows() {
  while IFS=$'\t' read -r s w pi p cmd; do
    [ "$cmd" = "claude" ] || continue
    c=$(tmux capture-pane -p -t "$p" 2>/dev/null) || c=""
    if printf '%s' "$c" | grep -q 'Esc to cancel' \
       && printf '%s' "$c" | grep -qE '❯[[:space:]]*[0-9]+\.[[:space:]]+[^[:space:]]'; then
      rank=0
      detail=$(printf '%s\n' "$c" | sed 's/[[:space:]]*$//' \
                 | grep -E '^(Do you want|Would you like)|\?$' | tail -1 | sed 's/^[[:space:]]*//')
      [ -z "$detail" ] && detail="needs a decision"
    elif printf '%s' "$c" | grep -qiE 'esc to interrupt|\([0-9].*tokens?\)'; then
      rank=1; detail="working…"
    else
      rank=2; detail="idle"
    fi
    printf '%d\t%s\t%s\t%s\t[%s:%s.%s] %s\n' "$rank" "$p" "$s" "$w" "$s" "$w" "$pi" "$detail"
  done < <(tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_index}	#{pane_id}	#{pane_current_command}')
}

tmp=$(mktemp "${TMPDIR:-/tmp}/claudewatch.XXXXXX")
rows | sort -t"$(printf '\t')" -k1,1n > "$tmp"
if [ ! -s "$tmp" ]; then
  rm -f "$tmp"
  tmux display-message "#[align=absolute-centre]there are no Claude sessions"
  exit 0
fi

n=$(wc -l < "$tmp" | tr -d ' ')
ch=$(tmux display-message -p '#{client_height}')
h=$(( n + 6 ))                                   # rows + border/label/prompt/padding
[ "$h" -lt 28 ] && h=28                           # floor so the preview stays readable
max=$(( ch * 90 / 100 )); [ "$h" -gt "$max" ] && h=$max

tmux display-popup -E -b none -x C -y C -w 90% -h "$h" \
  -e CW_POPUP=1 -e "CW_ROWS=$tmp" "$SELF"
