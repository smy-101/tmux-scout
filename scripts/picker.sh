#!/usr/bin/env bash
# tmux-scout picker — fzf popup to browse and jump to Claude Code sessions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.tmux-scout"
STATUS_FILE="$STATUS_DIR/status.json"
SESSIONS_DIR="$STATUS_DIR/sessions"

# --reload: called by fzf reload (run sync, output lines to stdout)
MODE="${1:-interactive}"

# Restore PATH
if scout_path=$(tmux show-environment -g SCOUT_PATH 2>/dev/null); then
    export PATH="${scout_path#SCOUT_PATH=}"
fi

# Ensure status file exists
if [ ! -f "$STATUS_FILE" ]; then
    mkdir -p "$STATUS_DIR"
    echo '{"version": 1, "sessions": {}}' > "$STATUS_FILE"
fi

CURRENT_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)

# Run sync only on reload — initial load uses cached data for instant display
if [ "$MODE" = "--reload" ]; then
    CURRENT_PANE="${2:-$CURRENT_PANE}"
    bash "$SCRIPT_DIR/sync.sh" 2>/dev/null || true
fi

# Generate fzf lines — single jq call extracts all fields at once
generate_lines() {
    local current_pane="${1:-}"

    # Print header
    printf "_\t  STATUS    AGENT   PROJECT                    TITLE\n"

    # Get tmux panes snapshot (single call)
    declare -A pane_commands
    while IFS='|' read -r p_id p_cmd p_dead; do
        pane_commands["$p_id"]="$p_cmd:$p_dead"
    done < <(tmux list-panes -a -F "#{pane_id}|#{pane_current_command}|#{pane_dead}" 2>/dev/null || true)

    # Use \x1f (Unit Separator) as delimiter — tab is whitespace, bash merges consecutive whitespace
    local SEP=$'\x1f'
    local found_any=0
    while IFS="$SEP" read -r tmux_pane sess_status needs_attention pending_tool session_title working_directory agent_type; do
        [ -z "$tmux_pane" ] && continue

        # Check pane exists and is alive
        local pane_info="${pane_commands[$tmux_pane]:-}"
        [ -z "$pane_info" ] && continue

        local pane_dead="${pane_info##*:}"
        [ "$pane_dead" = "1" ] && continue

        found_any=1

        # Build output parts
        local left_part="" agent_part="" project_part="" title_part=""

        # Current pane indicator + status
        if [ "$tmux_pane" = "$current_pane" ]; then
            left_part=$(printf '\033[33m*\033[0m')
        else
            left_part=" "
        fi

        if [ -n "$needs_attention" ]; then
            left_part="${left_part}$(printf ' \033[31m[ WAIT ]\033[0m')"
        elif [ "$sess_status" = "working" ]; then
            left_part="${left_part}$(printf ' \033[33m[ BUSY ]\033[0m')"
        elif [ "$sess_status" = "completed" ]; then
            left_part="${left_part}$(printf ' \033[32m[ DONE ]\033[0m')"
        else
            left_part="${left_part}$(printf ' \033[34m[ IDLE ]\033[0m')"
        fi

        # Agent (6 visible chars)
        local agent_plain
        agent_plain=$(printf "%-6s" "${agent_type:0:6}")
        case "$agent_type" in
            claude)
                agent_part=$'\033[38;5;209m'"${agent_plain}"$'\033[0m'
                ;;
            cursor)
                agent_part=$'\033[38;5;75m'"${agent_plain}"$'\033[0m'
                ;;
            copilot)
                agent_part=$'\033[38;5;114m'"${agent_plain}"$'\033[0m'
                ;;
            *)
                agent_part=$'\033[90m'"${agent_plain}"$'\033[0m'
                ;;
        esac

        # Project (25 visible chars) — bash string ops instead of basename command
        local project="${working_directory##*/}"
        [ ${#project} -gt 25 ] && project="${project:0:24}~"
        project_part=$(printf '%-25s' "$project")

        # Title
        if [ -n "$session_title" ]; then
            title_part=$'\033[2m"'"${session_title:0:80}"$'"\033[0m'
        fi

        # Tool details
        local detail=""
        if [ -n "$pending_tool" ]; then
            detail=$'\033[36m'"${pending_tool:0:40}"$'\033[0m'
        fi

        printf "%s\t%s  %s  %s  %s %s\n" "$tmux_pane" "$left_part" "$agent_part" "$project_part" "$title_part" "$detail"
    done < <(jq -r '
        .sessions[] | select(.endedAt == null)
        | [.tmuxPane // "", .status // "idle", .needsAttention // "",
           (.pendingToolUse.details // ""), (.sessionTitle // ""),
           (.workingDirectory // "?"), (.agentType // "unknown")]
        | @tsv | gsub("\t"; "\u001f")
    ' "$STATUS_FILE" 2>/dev/null)

    if [ "$found_any" = "0" ]; then
        printf "NONE\t$(printf '\033[2mNo active sessions found.\033[0m')\n"
    fi
}

# On reload: just output lines to stdout and exit (no fzf launch)
if [ "$MODE" = "--reload" ]; then
    generate_lines "$CURRENT_PANE"
    exit 0
fi

RELOAD_CMD="bash $(printf '%q' "$SCRIPT_DIR/picker.sh") --reload $(printf '%q' "$CURRENT_PANE")"
AUTO_FLAG="/tmp/tmux-scout-auto-$$"
PICKER_FLAG="/tmp/tmux-scout-picker-active"
LISTEN_PORT=$((10000 + RANDOM % 50000))

# Auto-refresh on by default
touch "$AUTO_FLAG"

# Cache lines and compute popup height
LINES_FILE=$(mktemp /tmp/tmux-scout-lines.XXXXXX)
generate_lines "$CURRENT_PANE" > "$LINES_FILE"
lines=$(wc -l < "$LINES_FILE" | tr -d ' ')
height=$((lines + 8))
[ "$height" -lt 12 ] && height=12
[ "$height" -gt 30 ] && height=30
echo $$ > "$PICKER_FLAG"

# Background auto-refresh daemon
(
    trap 'exit 0' TERM
    while true; do
        sleep 2 &
        wait $! || exit 0
        [ -f "$AUTO_FLAG" ] || continue
        T=$(date +%H:%M:%S)
        curl -sS -XPOST "localhost:$LISTEN_PORT" -d "reload($RELOAD_CMD)+change-border-label( tmux-scout · auto-refresh $T )" 2>/dev/null || break
    done
) &
AUTO_PID=$!

selected=$(cat "$LINES_FILE" | fzf \
    --listen=$LISTEN_PORT \
    --tmux "center,70%,$height,border-native" \
    --ansi \
    --no-mouse \
    --prompt='> ' \
    --color='border:bright-cyan,label:bright-white' \
    --delimiter='\t' \
    --with-nth=2 \
    --header=$'\nEnter: jump | Ctrl-R: refresh | Ctrl-T: auto-refresh | Esc: cancel' \
    --header-lines=1 \
    --bind="ctrl-r:reload($RELOAD_CMD)" \
    --bind="ctrl-t:execute-silent(if [ -f $AUTO_FLAG ]; then rm -f $AUTO_FLAG; else touch $AUTO_FLAG; fi)+reload($RELOAD_CMD)+transform:if [ -f $AUTO_FLAG ]; then printf \"change-border-label( tmux-scout · auto-refresh \$(date +%H:%M:%S) )\"; else printf 'change-border-label( tmux-scout )'; fi" \
    --layout=reverse-list \
    --border=rounded \
    --border-label=" tmux-scout · auto-refresh " \
    --border-label-pos=3 \
    --highlight-line \
    --info=inline-right \
    --separator="─" \
    --pointer="▶" \
    --no-sort \
    --cycle \
    || true)

kill $AUTO_PID 2>/dev/null; wait $AUTO_PID 2>/dev/null
rm -f "$LINES_FILE" "$AUTO_FLAG" "$PICKER_FLAG"
[ -z "$selected" ] && exit 0

pane_id=$(echo "$selected" | cut -f1)

if [ "$pane_id" = "NONE" ]; then
    exit 0
fi

# Jump to the pane
target=$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}' 2>/dev/null) || exit 0
tmux switch-client -t "$target" 2>/dev/null || tmux select-window -t "$target"
tmux select-pane -t "$pane_id"
