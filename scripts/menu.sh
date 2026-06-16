#!/bin/bash
# prefix-t popup: an fzf picker of every Claude session with a live preview. Selecting a
# row opens that session in a *live, interactive* tmux overlay (display-popup -> attach)
# so you can answer the agent in place and return by detaching (prefix d). Bound via
# run-shell -b so the popups never block the server. The picker re-execs this script with
# CW_POPUP=1 and records the chosen pane in CW_RES; the outer pass opens the overlay.
set -euo pipefail

FZF_COLORS="bg:#2E3440,fg:#D8DEE9,hl:#88C0D0,bg+:#3B4252,fg+:#ECEFF4,hl+:#5E81AC,pointer:#EBCB8B,border:#4C566A,label:#88C0D0"

# ---------- inside the picker popup: choose a row, record it ----------
if [ "${CW_POPUP:-}" = "1" ]; then
  sel=$(fzf --ansi --delimiter=$'\t' --with-nth=5 \
            --layout=reverse-list --border=rounded --border-label=' Claude sessions ' \
            --padding=1 --prompt='  ' --pointer='▶' --marker='▏' \
            --info=hidden --no-scrollbar \
            --preview 'tmux capture-pane -ep -t {2}' \
            --preview-window='right,55%,border-left' \
            --bind 'focus:refresh-preview' \
            --bind 'alt-1:execute-silent(tmux send-keys -t {2} 1 Enter)+refresh-preview' \
            --bind 'alt-2:execute-silent(tmux send-keys -t {2} 2 Enter)+refresh-preview' \
            --bind 'alt-3:execute-silent(tmux send-keys -t {2} 3 Enter)+refresh-preview' \
            --bind 'alt-c:execute-silent(tmux send-keys -t {2} Escape)+refresh-preview' \
            --color="$FZF_COLORS" < "$CW_ROWS") || exit 0
  [ -n "$sel" ] && printf '%s\t%s\t%s\n' \
    "$(printf '%s' "$sel" | cut -f2)" \
    "$(printf '%s' "$sel" | cut -f3)" \
    "$(printf '%s' "$sel" | cut -f4)" > "$CW_RES"
  exit 0
fi

# ---------- outside: build rows, run the picker, then open the live overlay ----------
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
res=$(mktemp "${TMPDIR:-/tmp}/claudewatch-res.XXXXXX")
trap 'rm -f "$tmp" "$res"' EXIT
rows | sort -t"$(printf '\t')" -k1,1n > "$tmp"
if [ ! -s "$tmp" ]; then
  tmux display-message "#[align=absolute-centre]there are no Claude sessions"
  exit 0
fi

n=$(wc -l < "$tmp" | tr -d ' ')
ch=$(tmux display-message -p '#{client_height}')
h=$(( n + 6 )); [ "$h" -lt 40 ] && h=40
max=$(( ch * 90 / 100 )); [ "$h" -gt "$max" ] && h=$max

tmux display-popup -E -b none -x C -y C -w 90% -h "$h" \
  -e CW_POPUP=1 -e "CW_ROWS=$tmp" -e "CW_RES=$res" "$SELF"

[ -s "$res" ] || exit 0
IFS=$'\t' read -r pid sess win < "$res"

# Land the target session on the chosen window/pane, then open it live in an overlay.
# unset TMUX so the nested attach is allowed; detach (prefix d) closes the overlay.
tmux select-window -t "$sess:$win" 2>/dev/null || true
tmux select-pane -t "$pid" 2>/dev/null || true
ov_h=$(( ch * 90 / 100 ))
tmux display-popup -E -b none -x C -y C -w 90% -h "$ov_h" \
  "unset TMUX; exec tmux attach-session -t '$sess'"
