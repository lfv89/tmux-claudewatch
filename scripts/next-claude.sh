#!/bin/bash
# Switch tmux focus to the next Claude pane after the current one (wrapping), in any
# state — waiting, thinking, or idle. A Claude pane is one whose foreground command is
# `claude`. Bound to `prefix n` by the plugin (see claudewatch.tmux).
set -euo pipefail

sess=(); win=(); pid=()
while IFS=$'\t' read -r s w p cmd; do
  [ "$cmd" = "claude" ] || continue
  sess+=("$s"); win+=("$w"); pid+=("$p")
done < <(tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_id}	#{pane_current_command}')

n=${#pid[@]}
if [ "$n" -eq 0 ]; then
  tmux display-message "#[align=absolute-centre]No Claude panes"
  exit 0
fi

cur=$(tmux display-message -p '#{pane_id}')
target=0   # default: first Claude pane (when the current pane isn't a Claude one)
for i in "${!pid[@]}"; do
  if [ "${pid[$i]}" = "$cur" ]; then
    target=$(( (i + 1) % n ))
    break
  fi
done

tmux switch-client -t "${sess[$target]}" 2>/dev/null || true
tmux select-window -t "${sess[$target]}:${win[$target]}"
tmux select-pane -t "${pid[$target]}"
