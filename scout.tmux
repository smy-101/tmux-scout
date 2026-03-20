#!/usr/bin/env bash
# tmux-scout - tmux plugin for monitoring and navigating Claude Code sessions
# Add this line to ~/.tmux.conf:
#   run-shell /path/to/tmux-scout/scout.tmux

# Get plugin directory
SCOUT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Set global environment
tmux set-environment -g SCOUT_DIR "$SCOUT_DIR"
tmux set-environment -g SCOUT_PATH "$PATH"

# Key binding: prefix + v
tmux bind-key v run-shell -b "$SCOUT_DIR/scripts/picker.sh"
