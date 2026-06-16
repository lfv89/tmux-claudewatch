#!/bin/bash
# Switch tmux focus to the next Claude-*waiting* pane after the current one (wrapping).
# Same detection as the macOS app: a numbered selection menu ("❯ 1. …") plus the dialog
# footer "Esc to cancel". Bound to `prefix N` by the plugin (see claudewatch.tmux).
set -euo pipefail

sess=(); win=(); pid=()
while IFS=$'\t' read -r s w p; do
  c=$(tmux capture-pane -p -t "$p" 2>/dev/null) || continue
  if printf '%s' "$c" | grep -q 'Esc to cancel' \
     && printf '%s' "$c" | grep -qE '❯[[:space:]]*[0-9]+\.[[:space:]]+[^[:space:]]'; then
    sess+=("$s"); win+=("$w"); pid+=("$p")
  fi
done < <(tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_id}')

n=${#pid[@]}
if [ "$n" -eq 0 ]; then
  tmux display-message "#[align=absolute-centre]there are no Claude sessions waiting"
  exit 0
fi

cur=$(tmux display-message -p '#{pane_id}')
target=0   # default: first waiting pane (when current pane isn't itself waiting)
for i in "${!pid[@]}"; do
  if [ "${pid[$i]}" = "$cur" ]; then
    target=$(( (i + 1) % n ))
    break
  fi
done

tmux switch-client -t "${sess[$target]}" 2>/dev/null || true
tmux select-window -t "${sess[$target]}:${win[$target]}"
tmux select-pane -t "${pid[$target]}"
