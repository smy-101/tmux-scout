#!/usr/bin/env bash
# tmux-scout hook setup script
# Installs/uninstalls hooks in ~/.claude/settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_PATH="$SCRIPT_DIR/hook.sh"
HOOK_IDENTIFIER="tmux-scout/scripts/hook.sh"

# Hook events to install
HOOK_EVENTS=("SessionStart" "UserPromptSubmit" "PreToolUse" "PostToolUse" "Stop" "SessionEnd")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Parse args
command=""
quiet=false
for arg in "$@"; do
    case "$arg" in
        install|uninstall|status) command="$arg" ;;
        --quiet|-q) quiet=true ;;
    esac
done

print_usage() {
    echo "Usage: $0 <install|uninstall|status> [--quiet]"
    exit 1
}

[ -z "$command" ] && print_usage

# Ensure hook script is executable
chmod +x "$HOOK_PATH"

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    if [ "$command" = "install" ]; then
        mkdir -p "$(dirname "$SETTINGS_FILE")"
        echo '{}' > "$SETTINGS_FILE"
    else
        echo -e "${YELLOW}Claude Code:${NC} settings.json not found"
        exit 0
    fi
fi

# Read current settings
settings=$(cat "$SETTINGS_FILE")

# Check if a hook is our scout hook
is_scout_hook() {
    local hook="$1"
    echo "$hook" | jq -r '.command // ""' | grep -q "$HOOK_IDENTIFIER"
}

install_hooks() {
    echo
    echo -e "${BOLD}tmux-scout hook setup${NC}"
    echo -e "${DIM}─────────────────────${NC}"
    echo
    echo -e "${CYAN}Claude Code${NC} ${DIM}($SETTINGS_FILE)${NC}"

    local changed=false

    # Ensure hooks object exists
    if ! echo "$settings" | jq -e '.hooks' > /dev/null 2>&1; then
        settings=$(echo "$settings" | jq '.hooks = {}')
        changed=true
    fi

    for event in "${HOOK_EVENTS[@]}"; do
        # Ensure event array exists
        if ! echo "$settings" | jq -e ".hooks[\"$event\"]" > /dev/null 2>&1; then
            settings=$(echo "$settings" | jq ".hooks[\"$event\"] = []")
            changed=true
        fi

        # Find catch-all matcher group (matcher: "")
        catch_all_index=$(echo "$settings" | jq --arg event "$event" '
            .hooks[$event] | to_entries | map(select(.value.matcher == "")) | .[0].key // -1
        ' 2>/dev/null || echo "-1")

        if [ "$catch_all_index" = "-1" ] || [ "$catch_all_index" = "null" ]; then
            # Create catch-all group at the beginning
            settings=$(echo "$settings" | jq --arg event "$event" '
                .hooks[$event] = [{"matcher": "", "hooks": []}] + .hooks[$event]
            ')
            catch_all_index=0
            changed=true
        fi

        # Check if our hook already exists in catch-all
        existing_index=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" '
            .hooks[$event][$idx].hooks | to_entries | map(select(.value.command | test("tmux-scout/scripts/hook.sh"))) | .[0].key // -1
        ' 2>/dev/null || echo "-1")

        hook_entry=$(jq -n --arg path "$HOOK_PATH" '{type: "command", command: ("bash \"" + $path + "\""), timeout: 5}')

        if [ "$existing_index" = "-1" ] || [ "$existing_index" = "null" ]; then
            # Add our hook
            settings=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" --argjson hook "$hook_entry" '
                .hooks[$event][$idx].hooks += [$hook]
            ')
            echo -e "  ${GREEN}✓${NC} $event ${DIM}hook installed${NC}"
            changed=true
        else
            # Check if path matches
            current_cmd=$(echo "$settings" | jq -r --arg event "$event" --argjson idx "$catch_all_index" --argjson hook_idx "$existing_index" '
                .hooks[$event][$idx].hooks[$hook_idx].command
            ')

            expected_cmd="bash \"$HOOK_PATH\""
            if [ "$current_cmd" = "$expected_cmd" ]; then
                echo -e "  ${GREEN}✓${NC} $event ${DIM}already installed${NC}"
            else
                # Update path
                settings=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" --argjson hook_idx "$existing_index" --argjson hook "$hook_entry" '
                    .hooks[$event][$idx].hooks[$hook_idx] = $hook
                ')
                echo -e "  ${YELLOW}↻${NC} $event ${DIM}path updated${NC}"
                changed=true
            fi
        fi
    done

    if [ "$changed" = true ]; then
        # Write atomically
        echo "$settings" > "${SETTINGS_FILE}.tmp.$$"
        mv "${SETTINGS_FILE}.tmp.$$" "$SETTINGS_FILE"
    fi

    echo
    echo "Done."
}

uninstall_hooks() {
    echo
    echo -e "${BOLD}tmux-scout hook removal${NC}"
    echo -e "${DIM}──────────────────────${NC}"
    echo
    echo -e "${CYAN}Claude Code${NC} ${DIM}($SETTINGS_FILE)${NC}"

    if ! echo "$settings" | jq -e '.hooks' > /dev/null 2>&1; then
        echo -e "  ${YELLOW}⊘${NC} ${DIM}no hooks configured${NC}"
        exit 0
    fi

    local changed=false

    for event in "${HOOK_EVENTS[@]}"; do
        if ! echo "$settings" | jq -e ".hooks[\"$event\"]" > /dev/null 2>&1; then
            echo -e "  ${DIM}·${NC} $event ${DIM}not found${NC}"
            continue
        fi

        # Find catch-all group
        catch_all_index=$(echo "$settings" | jq --arg event "$event" '
            .hooks[$event] | to_entries | map(select(.value.matcher == "")) | .[0].key // -1
        ' 2>/dev/null || echo "-1")

        if [ "$catch_all_index" = "-1" ] || [ "$catch_all_index" = "null" ]; then
            echo -e "  ${DIM}·${NC} $event ${DIM}not found${NC}"
            continue
        fi

        # Remove our hook from catch-all
        original_count=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" '.hooks[$event][$idx].hooks | length')

        settings=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" --arg ident "$HOOK_IDENTIFIER" '
            .hooks[$event][$idx].hooks = [.hooks[$event][$idx].hooks[] | select(.command | test($ident) | not)]
        ')

        new_count=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" '.hooks[$event][$idx].hooks | length')

        if [ "$original_count" -gt "$new_count" ]; then
            echo -e "  ${RED}✗${NC} $event ${DIM}removed${NC}"
            changed=true
        else
            echo -e "  ${DIM}·${NC} $event ${DIM}not found${NC}"
        fi

        # Remove empty catch-all group
        if [ "$new_count" -eq 0 ]; then
            settings=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" '
                .hooks[$event] = [.hooks[$event][] | select(.matcher != "")]
            ')
        fi

        # Remove empty event array
        event_count=$(echo "$settings" | jq --arg event "$event" '.hooks[$event] | length')
        if [ "$event_count" -eq 0 ]; then
            settings=$(echo "$settings" | jq --arg event "$event" 'del(.hooks[$event])')
        fi
    done

    # Remove empty hooks object
    hooks_count=$(echo "$settings" | jq '.hooks | keys | length')
    if [ "$hooks_count" -eq 0 ]; then
        settings=$(echo "$settings" | jq 'del(.hooks)')
    fi

    if [ "$changed" = true ]; then
        echo "$settings" > "${SETTINGS_FILE}.tmp.$$"
        mv "${SETTINGS_FILE}.tmp.$$" "$SETTINGS_FILE"
    fi

    echo
    echo "Done."
}

check_status() {
    if ! echo "$settings" | jq -e '.hooks' > /dev/null 2>&1; then
        [ "$quiet" = false ] && echo -e "${YELLOW}Claude Code:${NC} 0/${#HOOK_EVENTS[@]} hooks installed"
        exit 1
    fi

    local installed=0
    local missing=()

    for event in "${HOOK_EVENTS[@]}"; do
        catch_all_index=$(echo "$settings" | jq --arg event "$event" '
            .hooks[$event] | to_entries | map(select(.value.matcher == "")) | .[0].key // -1
        ' 2>/dev/null || echo "-1")

        if [ "$catch_all_index" = "-1" ] || [ "$catch_all_index" = "null" ]; then
            missing+=("$event")
            continue
        fi

        has_hook=$(echo "$settings" | jq --arg event "$event" --argjson idx "$catch_all_index" '
            .hooks[$event][$idx].hooks | map(select(.command | test("tmux-scout/scripts/hook.sh"))) | length > 0
        ' 2>/dev/null || echo "false")

        if [ "$has_hook" = "true" ]; then
            ((installed++))
        else
            missing+=("$event")
        fi
    done

    if [ "$quiet" = true ]; then
        [ "$installed" -eq "${#HOOK_EVENTS[@]}" ] || exit 1
        exit 0
    fi

    if [ "$installed" -eq "${#HOOK_EVENTS[@]}" ]; then
        echo -e "${GREEN}Claude Code:${NC} $installed/${#HOOK_EVENTS[@]} hooks installed ${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}Claude Code:${NC} $installed/${#HOOK_EVENTS[@]} hooks installed"
        [ ${#missing[@]} -gt 0 ] && echo -e "${DIM}  Missing: ${missing[*]}${NC}"
    fi
}

# Run command
case "$command" in
    install) install_hooks ;;
    uninstall) uninstall_hooks ;;
    status) check_status ;;
esac
