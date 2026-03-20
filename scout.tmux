# tmux-scout - tmux plugin for monitoring and navigating Claude Code sessions
# Add this line to ~/.tmux.conf:
#   run-shell /path/to/tmux-scout/scout.tmux

# Set plugin directory
%if "#{!=:#{SCOUT_DIR},}"
  set-environment -g SCOUT_DIR "/home/smy-101/study/tmux-scout"
%endif

# Default key binding (use @scout-key to customize)
bind-key v run-shell -b "/home/smy-101/study/tmux-scout/scripts/picker.sh"
