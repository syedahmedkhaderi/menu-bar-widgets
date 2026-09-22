#!/bin/zsh
# Removes the menu bar widgets and their login items.
#
#   ./uninstall.sh                all three
#   ./uninstall.sh monitor        only the named widget(s)
#
# Leaves SwiftBar installed (run "brew uninstall --cask swiftbar" to remove it too).
set -uo pipefail

UID_=$(id -u)

remove_native() {
  local name=$1 id=$2
  launchctl bootout "gui/$UID_/$id" 2>/dev/null
  pkill -x "$name" 2>/dev/null
  rm -rf "$HOME/Applications/$name.app" "$HOME/Library/LaunchAgents/$id.plist"
  defaults delete "$id" 2>/dev/null
  echo "Removed $name"
}

if (( $# )); then selected=("$@"); else selected=(stats monitor prayer); fi
for widget in $selected; do
  case $widget in
    stats) remove_native SysMeter com.syed.SysMeter ;;
    monitor) remove_native MonitorBrightness com.syed.MonitorBrightness ;;
    prayer)
      killall SwiftBar 2>/dev/null
      rm -f "$HOME/.swiftbar-plugins/prayer.1m.py"
      rm -rf "$HOME/.cache/prayer-times"
      osascript -e 'tell application "System Events" to delete login item "SwiftBar"' 2>/dev/null
      echo "Removed prayer" ;;
    *) echo "Unknown widget: $widget (use stats, monitor, prayer)" ;;
  esac
done
