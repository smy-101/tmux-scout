#!/usr/bin/env bash
# tmux-scout sync script
# Reconciles session state with actual tmux panes and processes

set -euo pipefail

STATUS_DIR="$HOME/.tmux-scout"
STATUS_FILE="$STATUS_DIR/status.json"
SESSIONS_DIR="$STATUS_DIR/sessions"

[ ! -f "$STATUS_FILE" ] && exit 0

now=$(date +%s)000

# Get all tmux panes snapshot using | as delimiter
declare -A panes
while IFS='|' read -r pane_id pane_pid pane_cmd pane_dead; do
    panes["$pane_id"]="$pane_pid:$pane_cmd:$pane_dead"
done < <(tmux list-panes -a -F "#{pane_id}|#{pane_pid}|#{pane_current_command}|#{pane_dead}" 2>/dev/null || true)

# Check if a PID is alive
is_pid_alive() {
    local pid=$1
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null
}

# Check if command is a shell
is_shell() {
    local cmd=$1
    case "$cmd" in
        bash|zsh|sh|fish|dash|ksh|tcsh|csh|nu) return 0 ;;
        *) return 1 ;;
    esac
}

# Detect pane state from content
detect_pane_state() {
    local pane_id=$1
    local content
    content=$(tmux capture-pane -t "$pane_id" -p -S -15 2>/dev/null || echo "")
    local tail=$(echo "$content" | tail -8 | tr '\n' ' ')

    # Check for busy state (thinking/generating)
    if echo "$tail" | grep -qE '✻ Thinking|∴ Thinking|[↓↑] [0-9.,]+[kKmM]? tokens\)'; then
        echo "working"
        return
    fi

    # Check for done state
    if echo "$tail" | grep -qE '✻ (Baked|Brewed|Churned|Cogitated|Cooked|Crunched|Sautéed|Worked) for'; then
        echo "completed"
        return
    fi

    # Check for needs attention
    if echo "$tail" | grep -qE 'Do you want to proceed|Would you like to proceed|Enter plan mode|Exit plan mode|Do you want to allow'; then
        echo "needsAttention"
        return
    fi

    # Check for idle
    if echo "$tail" | grep -q '✻ Idle'; then
        echo "completed"
        return
    fi

    echo ""
}

# Read status file
status=$(cat "$STATUS_FILE")
changed=false

# Process each session (only active ones)
shopt -s nullglob
for session_file in "$SESSIONS_DIR"/*.json; do
    [ -f "$session_file" ] || continue

    # Quick check: skip if already ended (grep is faster than jq)
    if grep -q '"endedAt":[0-9]' "$session_file" 2>/dev/null; then
        continue
    fi

    # Parse all needed fields in one jq call
    read -r tmux_pane pid current_status <<< "$(jq -r '[.tmuxPane // "", .pid // "", .status // "idle"] | @tsv' "$session_file")"

    # Skip sessions without pane (but still check if PID is alive)
    if [ -z "$tmux_pane" ]; then
        # For sessions without tmux pane, check if process is still alive
        if [ -n "$pid" ] && [ "$pid" != "null" ] && ! is_pid_alive "$pid"; then
            jq --argjson now "$now" '
                .status = "crashed"
                | .endedAt = ($now | tonumber)
                | .crashReason = "process exited (no tmux pane)"
            ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
            changed=true
        fi
        continue
    fi

    # Check if pane still exists
    pane_info="${panes[$tmux_pane]:-}"
    if [ -z "$pane_info" ]; then
        # Pane doesn't exist, mark as ended
        jq --argjson now "$now" '
            .status = "crashed"
            | .endedAt = ($now | tonumber)
            | .crashReason = "pane no longer exists"
        ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
        changed=true
        continue
    fi

    # Parse pane info
    IFS=':' read -r pane_pid pane_cmd pane_dead <<< "$pane_info"

    # Check for dead pane
    if [ "$pane_dead" = "1" ]; then
        jq --argjson now "$now" '
            .status = "crashed"
            | .endedAt = ($now | tonumber)
            | .crashReason = "pane is dead"
        ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
        changed=true
        continue
    fi

    # Check for crashed process
    if [ -n "$pid" ] && [ "$pid" != "null" ] && ! is_pid_alive "$pid"; then
        # PID is dead, mark session as ended
        jq --arg cmd "$pane_cmd" --argjson now "$now" '
            .status = "crashed"
            | .endedAt = ($now | tonumber)
            | .crashReason = ("process exited" + (if $cmd != "" then ", pane now: " + $cmd else "" end))
        ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
        changed=true
        continue
    fi

    # Detect state from pane content
    detected_state=$(detect_pane_state "$tmux_pane")

    if [ -n "$detected_state" ]; then
        case "$detected_state" in
            needsAttention)
                needs_attention=$(jq -r '.needsAttention // empty' "$session_file")
                if [ -z "$needs_attention" ]; then
                    jq --argjson now "$now" '
                        .needsAttention = "waiting for approval"
                        | .lastUpdated = ($now | tonumber)
                    ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
                    changed=true
                fi
                ;;
            working)
                needs_attention=$(jq -r '.needsAttention // empty' "$session_file")
                if [ "$current_status" != "working" ] || [ -n "$needs_attention" ]; then
                    jq --argjson now "$now" '
                        .status = "working"
                        | .needsAttention = null
                        | .pendingToolUse = null
                        | .lastUpdated = ($now | tonumber)
                    ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
                    changed=true
                fi
                ;;
            completed)
                needs_attention=$(jq -r '.needsAttention // empty' "$session_file")
                if [ "$current_status" != "completed" ] || [ -n "$needs_attention" ]; then
                    jq --argjson now "$now" '
                        .status = "completed"
                        | .needsAttention = null
                        | .pendingToolUse = null
                        | .lastUpdated = ($now | tonumber)
                    ' "$session_file" > "${session_file}.tmp.$$" && mv "${session_file}.tmp.$$" "$session_file"
                    changed=true
                fi
                ;;
        esac
    fi
done

# Update main status file if changed
if [ "$changed" = true ]; then
    # Rebuild status from session files
    status='{"version": 1, "lastUpdated": '"$now"', "sessions": {}}'
    for session_file in "$SESSIONS_DIR"/*.json; do
        [ -f "$session_file" ] || continue
        session=$(cat "$session_file")
        session_id=$(echo "$session" | jq -r '.sessionId')
        status=$(echo "$status" | jq --arg sid "$session_id" --argjson session "$session" '.sessions[$sid] = $session')
    done
    echo "$status" > "${STATUS_FILE}.tmp.$$"
    mv "${STATUS_FILE}.tmp.$$" "$STATUS_FILE"
fi
