#!/bin/bash
# Emits a tmux status segment for Claude sessions: robot + total, gear + thinking,
# bell + blocked. "blocked" = sitting on a permission/decision prompt; "thinking" =
# actively processing (spinner/timer line). Nothing is printed when total is 0.
# Meant for status-right:  #(/path/to/tmux-claudewatch/claudy-count.sh)
set -euo pipefail

total=0
blocked=0
thinking=0
while IFS=$'\t' read -r cmd pid; do
  [ "$cmd" = "claude" ] || continue
  total=$((total + 1))
  state=0
  c=$(tmux capture-pane -p -t "$pid" 2>/dev/null) || c=""
  if printf '%s' "$c" | grep -q 'Esc to cancel' \
     && printf '%s' "$c" | grep -qE '❯[[:space:]]*[0-9]+\.[[:space:]]+[^[:space:]]'; then
    blocked=$((blocked + 1))
    state=1
  elif printf '%s' "$c" | grep -qiE 'esc to interrupt|\([0-9].*tokens?\)'; then
    thinking=$((thinking + 1))
  fi
  # Tag the pane so pane-border-format can restyle a blocked active pane.
  cur=$(tmux show -p -t "$pid" -v @claude_blocked 2>/dev/null || true)
  if [ "$cur" != "$state" ]; then
    tmux set -p -t "$pid" @claude_blocked "$state" 2>/dev/null || true
  fi
done < <(tmux list-panes -a -F '#{pane_current_command}	#{pane_id}')

[ "$total" -eq 0 ] && exit 0

# Theme-native: yellow icons, white numbers — robot + total, gear + thinking, bell +
# blocked — then the thin-chevron segment separator (U+E0B3), matching clock/calendar.
sep=$'\xee\x82\xb3'
printf '#[fg=yellow]󰚩 #[fg=white]%d #[fg=yellow]󰒓 #[fg=white]%d #[fg=yellow]󰂚 #[fg=white]%d %s ' \
  "$total" "$thinking" "$blocked" "$sep"
exit 0
