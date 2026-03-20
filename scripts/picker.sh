#!/usr/bin/env bash
# tmux-scout picker — fzf popup to browse and jump to Claude Code sessions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.tmux-scout"
STATUS_FILE="$STATUS_DIR/status.json"
SESSIONS_DIR="$STATUS_DIR/sessions"

# Restore PATH
if scout_path=$(tmux show-environment -g SCOUT_PATH 2>/dev/null); then
    export PATH="${scout_path#SCOUT_PATH=}"
fi

# Ensure status file exists
if [ ! -f "$STATUS_FILE" ]; then
    mkdir -p "$STATUS_DIR"
    echo '{"version": 1, "sessions": {}}' > "$STATUS_FILE"
fi

# Run sync first
bash "$SCRIPT_DIR/sync.sh" 2>/dev/null || true

CURRENT_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
RELOAD_CMD="bash $(printf '%q' "$SCRIPT_DIR/picker.sh")"
AUTO_FLAG="/tmp/tmux-scout-auto-$$"
LISTEN_PORT=$((10000 + RANDOM % 50000))

# Auto-refresh on by default
touch "$AUTO_FLAG"

# Generate fzf lines
generate_lines() {
    local current_pane="${1:-}"

    # Print header (align with data columns)
    printf "_\t  STATUS    AGENT     PROJECT                      TITLE\n"

    # Get tmux panes snapshot
    declare -A pane_commands
    while IFS='|' read -r pane_id pane_cmd pane_dead; do
        pane_commands["$pane_id"]="$pane_cmd:$pane_dead"
    done < <(tmux list-panes -a -F "#{pane_id}|#{pane_current_command}|#{pane_dead}" 2>/dev/null || true)

    # Process each session JSON line by line
    local found_any=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Extract fields using jq
        local tmux_pane sess_status needs_attention pending_tool session_title working_directory agent_type
        tmux_pane=$(echo "$line" | jq -r '.tmuxPane // empty')
        [ -z "$tmux_pane" ] && continue

        # Check pane exists and is alive
        local pane_info="${pane_commands[$tmux_pane]:-}"
        [ -z "$pane_info" ] && continue

        local pane_cmd pane_dead
        pane_cmd=$(echo "$pane_info" | cut -d: -f1)
        pane_dead=$(echo "$pane_info" | cut -d: -f2)
        [ "$pane_dead" = "1" ] && continue

        # Extract other fields
        sess_status=$(echo "$line" | jq -r '.status // "idle"')
        needs_attention=$(echo "$line" | jq -r '.needsAttention // empty')
        pending_tool=$(echo "$line" | jq -r '.pendingToolUse.details // empty')
        session_title=$(echo "$line" | jq -r '.sessionTitle // empty')
        working_directory=$(echo "$line" | jq -r '.workingDirectory // "?"')
        agent_type=$(echo "$line" | jq -r '.agentType // "unknown"')

        found_any=1

        # Build output parts
        local left_part="" agent_part="" project_part="" title_part=""

        # Current pane indicator + status (total 11 visible chars: "  [STATUS]")
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

        # Agent (8 visible chars)
        local agent_plain
        agent_plain=$(printf "%-8s" "${agent_type:0:8}")
        case "$agent_type" in
            claude)
                agent_part=$(printf ' \033[38;5;209m%s\033[0m' "$agent_plain")
                ;;
            cursor)
                agent_part=$(printf ' \033[38;5;75m%s\033[0m' "$agent_plain")
                ;;
            copilot)
                agent_part=$(printf ' \033[38;5;114m%s\033[0m' "$agent_plain")
                ;;
            *)
                agent_part=$(printf ' \033[90m%s\033[0m' "$agent_plain")
                ;;
        esac

        # Project (25 visible chars)
        local project
        project=$(basename "$working_directory")
        [ ${#project} -gt 25 ] && project="${project:0:24}~"
        project_part=$(printf ' %-25s' "$project")

        # Title
        if [ -n "$session_title" ]; then
            title_part=$(printf ' \033[2m"%s"\033[0m' "${session_title:0:80}")
        fi

        # Tool details
        local detail=""
        if [ -n "$pending_tool" ]; then
            detail=$(printf '  \033[36m%s\033[0m' "${pending_tool:0:40}")
        fi

        printf "%s\t%s%s%s%s%s\n" "$tmux_pane" "$left_part" "$agent_part" "$project_part" "$title_part" "$detail"
    done < <(jq -c '.sessions[] | select(.endedAt == null)' "$STATUS_FILE" 2>/dev/null)

    if [ "$found_any" = "0" ]; then
        printf "NONE\t$(printf '\033[2mNo active sessions found.\033[0m')\n"
    fi
}

# Cache lines and compute popup height
LINES_FILE=$(mktemp /tmp/tmux-scout-lines.XXXXXX)
generate_lines "$CURRENT_PANE" > "$LINES_FILE"
lines=$(wc -l < "$LINES_FILE" | tr -d ' ')
height=$((lines + 8))
[ "$height" -lt 12 ] && height=12
[ "$height" -gt 30 ] && height=30

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
rm -f "$LINES_FILE" "$AUTO_FLAG"
[ -z "$selected" ] && exit 0

pane_id=$(echo "$selected" | cut -f1)

if [ "$pane_id" = "NONE" ]; then
    exit 0
fi

# Jump to the pane
target=$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}' 2>/dev/null) || exit 0
tmux switch-client -t "$target" 2>/dev/null || tmux select-window -t "$target"
tmux select-pane -t "$pane_id"
