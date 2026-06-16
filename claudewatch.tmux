#!/usr/bin/env bash
# TPM entry point. TPM sources every executable *.tmux file in a plugin's root.
# This wires up two things:
#   1. The status segment — replaces a #{claudewatch} token in status-left/right with
#      a call to scripts/claude-count.sh (same idiom as tmux-containers' #{containers}).
#   2. The keys — `prefix n` cycles every Claude pane, `prefix N` cycles only the waiting
#      ones, `prefix t` opens an fzf popup of all of them. All configurable; set the
#      option empty to leave a key unbound.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_format="#($CURRENT_DIR/scripts/claude-count.sh)"

get_tmux_option() {
  local option="$1" default_value="$2" value
  value="$(tmux show-option -gqv "$option")"
  [ -z "$value" ] && echo "$default_value" || echo "$value"
}

# Replace #{claudewatch} in a status option with the count-script invocation.
replace_token() {
  local option="$1" format="$2" line
  line="$(tmux show-option -gqv "$option")"
  case "$line" in
    *'#{claudewatch}'*)
      tmux set-option -gq "$option" "${line//#\{claudewatch\}/$format}"
      ;;
  esac
}

main() {
  local format jump_key waiting_key menu_key
  format="$(get_tmux_option @claudewatch_format "$default_format")"
  replace_token status-right "$format"
  replace_token status-left "$format"

  jump_key="$(get_tmux_option @claudewatch_jump_key n)"           # all Claude panes
  waiting_key="$(get_tmux_option @claudewatch_jump_waiting_key N)" # waiting panes only
  menu_key="$(get_tmux_option @claudewatch_menu_key t)"           # fzf popup of all panes
  [ -n "$jump_key" ]    && tmux bind-key "$jump_key"    run-shell "$CURRENT_DIR/scripts/next-claude.sh"
  [ -n "$waiting_key" ] && tmux bind-key "$waiting_key" run-shell "$CURRENT_DIR/scripts/next-waiting.sh"
  [ -n "$menu_key" ]    && tmux bind-key "$menu_key" \
      display-popup -x C -y C -w 80% -h 60% -b rounded -E "$CURRENT_DIR/scripts/menu.sh"
}

main
