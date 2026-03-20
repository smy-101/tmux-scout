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

    # Print header
    printf "_\t  STATUS   PROJECT                      TITLE\n"

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
        local tmux_pane sess_status needs_attention pending_tool session_title working_directory
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

        found_any=1

        # Format status tag
        local tag
        if [ -n "$needs_attention" ]; then
            tag=$(printf '\033[31m[ WAIT ]\033[0m')
        elif [ "$sess_status" = "working" ]; then
            tag=$(printf '\033[33m[ BUSY ]\033[0m')
        elif [ "$sess_status" = "completed" ]; then
            tag=$(printf '\033[32m[ DONE ]\033[0m')
        else
            tag=$(printf '\033[34m[ IDLE ]\033[0m')
        fi

        # Current pane indicator
        local cur=" "
        if [ "$tmux_pane" = "$current_pane" ]; then
            cur=$(printf '\033[33m*\033[0m')
        fi

        # Project name
        local project
        project=$(basename "$working_directory")
        [ ${#project} -gt 25 ] && project="${project:0:24}~"
        project=$(printf "%-25s" "$project")

        # Title
        local title=""
        if [ -n "$session_title" ]; then
            title="$(printf '\033[2m"%s"\033[0m' "${session_title:0:50}")"
        fi

        # Tool details
        local detail=""
        if [ -n "$pending_tool" ]; then
            detail="$(printf '  \033[36m%s\033[0m' "${pending_tool:0:40}")"
        fi

        printf "%s\t%s %s $(printf '\033[38;5;209m')claude$(printf '\033[0m') %s %s%s\n" "$tmux_pane" "$cur" "$tag" "$project" "$title" "$detail"
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
    --tmux "center,85%,$height,border-native" \
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
    --preview='tmux capture-pane -pJ -t {1} 2>/dev/null | tail -40' \
    --preview-window=right:50%:wrap:border-left \
    --preview-label=" pane preview " \
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
