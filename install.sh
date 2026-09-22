#!/bin/zsh
# Installs the menu bar widgets and makes them start at login.
#
#   ./install.sh                  all three: stats, monitor, prayer
#   ./install.sh stats            only the named widget(s)
#
# stats and monitor are native Swift apps: built with swiftc, installed to
# ~/Applications, started at login by a LaunchAgent. prayer is a SwiftBar plugin.
# Reinstalling monitor resets its Accessibility permission (the app is ad-hoc signed).
set -euo pipefail

ROOT=${0:A:h}
BUILD="$ROOT/build"
DEST="$HOME/Applications"
AGENTS="$HOME/Library/LaunchAgents"
UID_=$(id -u)

# widget | app name | bundle id | extra swiftc flags
NATIVE=(
  "stats|SysMeter|com.syed.SysMeter|"
  "monitor|MonitorBrightness|com.syed.MonitorBrightness|-import-objc-header $ROOT/monitor/IOAVService.h"
)

install_native() {
  local widget=$1 name=$2 id=$3 extra=$4
  echo "==> Building $name ($widget)"
  local app="$BUILD/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$DEST" "$AGENTS"

  swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
    ${=extra} "$ROOT/$widget"/*.swift \
    -framework AppKit -framework IOKit -framework SwiftUI -framework ApplicationServices \
    -o "$app/Contents/MacOS/$name"

  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
  codesign --force --sign - "$app" 2>/dev/null

  echo "==> Installing $name"
  launchctl bootout "gui/$UID_/$id" 2>/dev/null || true
  pkill -x "$name" 2>/dev/null || true
  rm -rf "$DEST/$name.app"
  cp -R "$app" "$DEST/"

  # KeepAlive only on crashes: choosing Quit (exit 0) keeps it quit until next login.
  cat > "$AGENTS/$id.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$id</string>
  <key>Program</key><string>$DEST/$name.app/Contents/MacOS/$name</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$UID_" "$AGENTS/$id.plist"
}

install_prayer() {
  echo "==> Installing prayer (SwiftBar plugin)"
  local plugins="$HOME/.swiftbar-plugins"
  [[ -d /Applications/SwiftBar.app ]] || brew install --cask swiftbar
  # SwiftBar reads the plugin from ~/.swiftbar-plugins: reading from Downloads would need a permission prompt.
  mkdir -p "$plugins"
  cp "$ROOT/prayer/prayer.1m.py" "$plugins/"
  chmod +x "$plugins/prayer.1m.py"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$plugins"
  if ! osascript -e 'tell application "System Events" to get the name of every login item' | grep -q SwiftBar; then
    osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null
  fi
  killall SwiftBar 2>/dev/null || true
  sleep 1
  open -a SwiftBar
}

if (( $# )); then selected=("$@"); else selected=(stats monitor prayer); fi
for widget in $selected; do
  case $widget in
    prayer) install_prayer ;;
    stats|monitor)
      for spec in $NATIVE; do
        IFS='|' read -r w name id extra <<< "$spec"
        if [[ $w == $widget ]]; then install_native "$w" "$name" "$id" "$extra"; fi
      done ;;
    *) echo "Unknown widget: $widget (use stats, monitor, prayer)"; exit 1 ;;
  esac
done
echo "Done. Installed widgets are running and start at login."
