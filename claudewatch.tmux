#!/usr/bin/env bash
# TPM entry point. TPM sources every executable *.tmux file in a plugin's root.
# This wires up two things:
#   1. The status segment — replaces a #{claudewatch} token in status-left/right with
#      a call to scripts/claude-count.sh (same idiom as tmux-containers' #{containers}).
#   2. The jump keys — `prefix n` cycles every Claude pane, `prefix N` cycles only the
#      blocked ones. Both are configurable; set the option empty to leave a key unbound.

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
  local format jump_key blocked_key
  format="$(get_tmux_option @claudewatch_format "$default_format")"
  replace_token status-right "$format"
  replace_token status-left "$format"

  jump_key="$(get_tmux_option @claudewatch_jump_key n)"           # all Claude panes
  blocked_key="$(get_tmux_option @claudewatch_jump_blocked_key N)" # blocked panes only
  [ -n "$jump_key" ]    && tmux bind-key "$jump_key"    run-shell "$CURRENT_DIR/scripts/next-claude.sh"
  [ -n "$blocked_key" ] && tmux bind-key "$blocked_key" run-shell "$CURRENT_DIR/scripts/next-blocked.sh"
}

main
