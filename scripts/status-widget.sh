#!/usr/bin/env bash
# tmux-scout status widget for tmux status bar
# Shows counts: W=waiting, B=busy, D=done

set -euo pipefail

STATUS_FILE="$HOME/.tmux-scout/status.json"

[ ! -f "$STATUS_FILE" ] && exit 0

# Run sync first (silently)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/sync.sh" 2>/dev/null || true

# Count sessions by status
wait_count=0
busy_count=0
done_count=0

while IFS= read -r session; do
    [ -z "$session" ] && continue

    status=$(echo "$session" | jq -r '.status')
    needs=$(echo "$session" | jq -r '.needsAttention // empty')
    ended=$(echo "$session" | jq -r '.endedAt // empty')
    tmux_pane=$(echo "$session" | jq -r '.tmuxPane // empty')

    # Skip ended or unbound sessions
    [ -n "$ended" ] && [ "$ended" != "null" ] && continue
    [ -z "$tmux_pane" ] && continue

    if [ -n "$needs" ]; then
        ((wait_count++))
    elif [ "$status" = "working" ]; then
        ((busy_count++))
    elif [ "$status" = "completed" ]; then
        ((done_count++))
    fi
done < <(jq -c '.sessions[]' "$STATUS_FILE" 2>/dev/null)

# Format output with colors
output=""
[ "$wait_count" -gt 0 ] && output="${output}\033[31m${wait_count}\033[0m|"
[ "$busy_count" -gt 0 ] && output="${output}\033[33m${busy_count}\033[0m|"
output="${output}\033[32m${done_count}\033[0m"

echo -e "$output"
