#!/usr/bin/env bash
# tmux-scout Claude Code hook handler
# Reads JSON from stdin and updates session status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.tmux-scout"
STATUS_FILE="$STATUS_DIR/status.json"
SESSIONS_DIR="$STATUS_DIR/sessions"

# Ensure directories exist
mkdir -p "$SESSIONS_DIR"

# Read stdin
input=$(cat)

# Parse JSON fields
session_id=$(echo "$input" | jq -r '.session_id // empty')
[ -z "$session_id" ] && exit 0

hook_event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
prompt=$(echo "$input" | jq -r '.prompt // empty')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
tool_input=$(echo "$input" | jq -r '.tool_input // empty')
reason=$(echo "$input" | jq -r '.reason // empty')

# tmux pane info
tmux_pane="${TMUX_PANE:-}"
pid=$PPID
now=$(date +%s)000

# Sanitize session ID for filename
session_file="$SESSIONS_DIR/${session_id//[:\/\\]/_}.json"

# Read existing session or create new
if [ -f "$session_file" ]; then
    session=$(cat "$session_file")
else
    session=$(jq -n --arg sid "$session_id" --arg now "$now" \
        '{sessionId: $sid, agentType: "claude", startedAt: ($now | tonumber), status: "idle"}')
fi

# Process based on event type
case "$hook_event" in
    SessionStart)
        session=$(echo "$session" | jq --arg cwd "$cwd" --arg pane "$tmux_pane" --argjson pid "$pid" --argjson now "$now" '
            .status = "idle"
            | .workingDirectory = $cwd
            | .startedAt = ($now | tonumber)
            | .pendingToolUse = null
            | .tmuxPane = $pane
            | .pid = $pid
            | .lastEvent = {type: "session_start", timestamp: ($now | tonumber)}
            | .endedAt = null
            | .needsAttention = null
        ')
        ;;

    UserPromptSubmit)
        # Extract clean title from prompt
        title=$(echo "$prompt" | sed -E 's/<system[-_]?(instruction|reminder)[^>]*>.*<\/system[-_]?\1>//gi' | head -c 100 | tr '\n' ' ')
        session=$(echo "$session" | jq --arg title "$title" --arg cwd "$cwd" --arg pane "$tmux_pane" --argjson pid "$pid" --argjson now "$now" '
            .status = "working"
            | .workingDirectory = $cwd
            | .sessionTitle = (if $title != "" then $title else .sessionTitle end)
            | .pendingToolUse = null
            | .tmuxPane = $pane
            | .pid = $pid
            | .lastEvent = {type: "prompt_submit", timestamp: ($now | tonumber), details: $title}
            | .needsAttention = null
        ')
        ;;

    PreToolUse)
        # Build tool details string
        tool_details="$tool_name"
        if [ "$tool_input" != "null" ] && [ -n "$tool_input" ]; then
            cmd=$(echo "$tool_input" | jq -r '.command // empty')
            file_path=$(echo "$tool_input" | jq -r '.file_path // empty')
            pattern=$(echo "$tool_input" | jq -r '.pattern // empty')

            if [ -n "$cmd" ]; then
                tool_details="$tool_name: ${cmd:0:50}"
            elif [ -n "$file_path" ]; then
                tool_details="$tool_name: $(basename "$file_path")"
            elif [ -n "$pattern" ]; then
                tool_details="$tool_name: ${pattern:0:30}"
            fi
        fi

        # Check if needs attention
        needs_attention=""
        case "$tool_name" in
            ExitPlanMode|AskUserQuestion)
                needs_attention="$tool_name"
                ;;
        esac

        session=$(echo "$session" | jq --arg tool "$tool_name" --arg details "$tool_details" --arg attention "$needs_attention" --arg pane "$tmux_pane" --argjson pid "$pid" --argjson now "$now" '
            .status = "working"
            | .needsAttention = (if $attention != "" then $attention else null end)
            | .pendingToolUse = {tool: $tool, details: $details, timestamp: ($now | tonumber)}
            | .lastEvent = {type: "tool_use", timestamp: ($now | tonumber), details: $details}
            | .tmuxPane = $pane
            | .pid = $pid
        ')
        ;;

    PostToolUse)
        session=$(echo "$session" | jq --arg pane "$tmux_pane" --argjson pid "$pid" --argjson now "$now" '
            .status = "working"
            | .pendingToolUse = null
            | .tmuxPane = $pane
            | .pid = $pid
        ')
        ;;

    Stop)
        session=$(echo "$session" | jq --argjson now "$now" '
            .status = "completed"
            | .needsAttention = null
            | .pendingToolUse = null
            | .lastEvent = {type: "stop", timestamp: ($now | tonumber)}
        ')
        ;;

    SessionEnd)
        session=$(echo "$session" | jq --arg reason "$reason" --argjson now "$now" '
            .status = "idle"
            | .endedAt = ($now | tonumber)
            | .needsAttention = null
            | .pendingToolUse = null
            | .lastEvent = {type: "session_end", timestamp: ($now | tonumber), details: $reason}
        ')
        ;;
esac

# Update timestamp
session=$(echo "$session" | jq --argjson now "$now" '.lastUpdated = ($now | tonumber)')

# Write session file atomically
echo "$session" > "${session_file}.tmp.$$"
mv "${session_file}.tmp.$$" "$session_file"

# Update main status file
if [ -f "$STATUS_FILE" ]; then
    status=$(cat "$STATUS_FILE")
else
    status='{"version": 1, "sessions": {}}'
fi

# Merge session into status
status=$(echo "$status" | jq --arg sid "$session_id" --argjson session "$session" --argjson now "$now" '
    .sessions[$sid] = $session
    | .lastUpdated = ($now | tonumber)
')

# Clean up old sessions (older than 24h)
cutoff=$(($(date +%s) - 86400))000
status=$(echo "$status" | jq --argjson cutoff "$cutoff" '
    .sessions |= with_entries(select(.value.endedAt == null or .value.endedAt > $cutoff))
')

# Write status file atomically
echo "$status" > "${STATUS_FILE}.tmp.$$"
mv "${STATUS_FILE}.tmp.$$" "$STATUS_FILE"
