#!/usr/bin/env bash
# Toggle the statusline on/off without touching settings.json.
# Usage: ./toggle.sh on | off | status

FLAG="$HOME/.claude/.statusline-disabled"

case "$1" in
  off) touch "$FLAG"; echo "statusline: off" ;;
  on)  rm -f "$FLAG"; echo "statusline: on" ;;
  status) [ -f "$FLAG" ] && echo "statusline: off" || echo "statusline: on" ;;
  *) echo "usage: $0 {on|off|status}"; exit 1 ;;
esac
