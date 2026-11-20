#!/bin/bash
# Temporary. Records what GitHub's Xcode 27 image offers for driving the iPhone Duo
# simulator: its displays, its posture and its rotation. The test workflow needs
# that to render the app the way the open device shows it. Delete this folder and
# .github/workflows/duo-probe.yml once the test workflow does so.
set -u

: "${SIM_NAME:?}" "${SIM_OS:?}" "${DEVELOPER_DIR:?}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${GITHUB_WORKSPACE:-$PWD}/out"
SIMULATOR_APP="$DEVELOPER_DIR/Applications/Simulator.app"
mkdir -p "$OUT"

# Runs a command and stops it after a number of seconds. macOS has no timeout(1).
guard() {
  local seconds=$1 waited=0 pid
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      echo "stopped after ${seconds}s: $*"
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

section() { printf '\n=== %s\n' "$*"; }

# Saves what each of the two built-in displays shows, and the display list.
shot() {
  guard 40 xcrun simctl io "$udid" screenshot --display=primary "$OUT/$1-outer.png"
  guard 40 xcrun simctl io "$udid" screenshot --display=primary-1 "$OUT/$1-inner.png"
  guard 30 xcrun simctl io "$udid" enumerate > "$OUT/$1-displays.txt" 2>&1
}

# Clicks an item of the Simulator app's menus, named by two or three titles.
click_menu() {
  guard 40 osascript "$HERE/simulator_click.applescript" "$@"
}

udid=$(xcrun simctl list devices available | awk -v section="-- iOS $SIM_OS --" -v prefix="    $SIM_NAME (" '
  /^-- / { inside = ($0 == section) }
  inside && index($0, prefix) == 1 {
    rest = substr($0, length(prefix) + 1)
    print substr(rest, 1, index(rest, ")") - 1)
    exit
  }')
echo "simulator $udid"
if [ -z "$udid" ]; then
  xcrun simctl list devices available
  exit 1
fi

section "help texts"
for topic in ui io boot launch spawn status_bar; do
  guard 30 xcrun simctl help "$topic" > "$OUT/help-$topic.txt" 2>&1
done
guard 30 xcrun simctl list devicetypes > "$OUT/devicetypes.txt" 2>&1
guard 30 xcrun simctl list runtimes > "$OUT/runtimes.txt" 2>&1

section "words in the simulator tools"
# Prints the strings of a binary that match a pattern.
words() {
  echo "--- $1 ~ $2"
  if [ -f "$1" ]; then
    strings -a "$1" | grep -i -E "$2" | sort -u | head -n "$3"
  else
    echo "not there"
  fi
}
{
  ls /Library/Developer/PrivateFrameworks
  ls "$DEVELOPER_DIR/Library/PrivateFrameworks" | grep -i simulator
  for binary in "$DEVELOPER_DIR/usr/bin/simctl" \
      /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator \
      "$DEVELOPER_DIR/Library/PrivateFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit" \
      "$SIMULATOR_APP/Contents/MacOS/Simulator"; do
    words "$binary" 'posture|hinge|unfold|foldab|folded|folding|clamshell' 400
    words "$binary" 'screenconfig|resizable|orientation|rotat' 300
  done
} > "$OUT/words.txt" 2>&1
{
  find "$SIMULATOR_APP/Contents/Resources" -maxdepth 2 | head -200
  find "$SIMULATOR_APP/Contents/Resources" -type f \( -name "*.nib" -o -name "*.loctable" -o -name "*.strings" \) | while read -r file; do
    case "$file" in
      *.nib) text=$(strings -a "$file") ;;
      *) text=$(plutil -p "$file" 2>/dev/null) ;;
    esac
    found=$(printf '%s\n' "$text" | grep -i -E 'posture|hinge|fold|clamshell|rotat' | grep -v -i 'folder' | sort -u | head -60)
    if [ -n "$found" ]; then
      echo "--- $file"
      printf '%s\n' "$found"
    fi
  done
} > "$OUT/simulator-app-words.txt" 2>&1

section "device type"
{
  for root in /Library/Developer/CoreSimulator/Profiles/DeviceTypes \
      "$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes"; do
    echo "--- $root"
    find "$root" -maxdepth 1 -iname "*Duo*" 2>/dev/null | while read -r bundle; do
      echo "--- $bundle"
      find "$bundle" -type f | head -40
      for plist in "$bundle/Contents/Resources/profile.plist" "$bundle/Contents/Resources/capabilities.plist"; do
        echo "--- $plist"
        plutil -p "$plist"
      done
    done
  done
} > "$OUT/devicetype.txt" 2>&1

section "boot"
guard 300 xcrun simctl boot "$udid"
guard 420 xcrun simctl bootstatus "$udid" -b
shot 1-booted

section "a system app"
guard 60 xcrun simctl launch "$udid" com.apple.Preferences
sleep 10
shot 2-settings

section "simctl options"
{
  echo "--- ui"
  guard 20 xcrun simctl ui "$udid"
  for option in appearance content_size increase_contrast posture hinge fold orientation; do
    echo "--- ui $option"
    guard 20 xcrun simctl ui "$udid" "$option"
  done
  for subcommand in posture hinge fold unfold rotate orientation; do
    echo "--- $subcommand"
    guard 20 xcrun simctl "$subcommand" "$udid"
    echo "--- io $subcommand"
    guard 20 xcrun simctl io "$udid" "$subcommand"
  done
} > "$OUT/simctl-options.txt" 2>&1

section "inside the simulator"
{
  echo "--- launchd environment"
  guard 40 xcrun simctl spawn "$udid" launchctl print system | grep -i -E "SIMULATOR_|posture|hinge|fold" | head -100
  for domain in com.apple.backboardd com.apple.springboard com.apple.frontboard; do
    echo "--- defaults $domain"
    guard 20 xcrun simctl spawn "$udid" defaults read "$domain" | grep -i -E "posture|hinge|fold|display" | head -40
  done
} > "$OUT/inside-simulator.txt" 2>&1

section "Simulator app"
open -a "$SIMULATOR_APP" --args -CurrentDeviceUDID "$udid"
sleep 30
guard 30 screencapture -x "$OUT/3-desktop.png"
guard 120 osascript "$HERE/simulator_menus.applescript" > "$OUT/simulator-menus.txt" 2> "$OUT/simulator-menus-errors.txt"
guard 30 osascript -e 'tell application "System Events" to tell process "Simulator" to get name of every window' > "$OUT/simulator-windows.txt" 2>&1
guard 90 osascript -e 'tell application "System Events" to tell process "Simulator" to get entire contents of every window' 2>&1 \
  | tr ',' '\n' > "$OUT/simulator-window-contents.txt"
guard 20 defaults read com.apple.iphonesimulator > "$OUT/simulator-defaults.txt" 2>&1
shot 3-simulator-app

section "posture items in the menus"
grep -i -E "posture|hinge|fold|clamshell" "$OUT/simulator-menus.txt" | grep -v -i "folder" > "$OUT/menu-candidates.txt"
count=0
while IFS=$'\t' read -r -u 3 path enabled mark; do
  # An item that only opens a submenu is not a command.
  if grep -q -F "$path > " "$OUT/simulator-menus.txt"; then
    continue
  fi
  count=$((count + 1))
  if [ "$enabled" != "enabled" ]; then
    printf '%s\t%s\tskipped, %s\n' "$count" "$path" "$enabled" >> "$OUT/menu-clicks.txt"
    continue
  fi
  top=${path%% > *}
  rest=${path#* > }
  if [ "$rest" != "${rest#* > }" ]; then
    result=$(click_menu "$top" "${rest%% > *}" "${rest#* > }" 2>&1)
  else
    result=$(click_menu "$top" "$rest" 2>&1)
  fi
  printf '%s\t%s\tmark before: %s\t%s\n' "$count" "$path" "$mark" "$result" >> "$OUT/menu-clicks.txt"
  sleep 8
  shot "4-$count"
  guard 30 screencapture -x "$OUT/4-$count-desktop.png"
done 3< "$OUT/menu-candidates.txt"
guard 120 osascript "$HERE/simulator_menus.applescript" > "$OUT/simulator-menus-after.txt" 2>&1

section "rotation"
for item in "Rotate Left" "Rotate Right"; do
  name=$(printf '%s' "$item" | tr 'A-Z ' 'a-z-')
  click_menu Device "$item" > "$OUT/5-$name.txt" 2>&1
  sleep 8
  shot "5-$name"
  guard 30 screencapture -x "$OUT/5-$name-desktop.png"
done

section "screen power"
{
  echo "--- outer off"
  guard 30 xcrun simctl io "$udid" screenConfig --display=primary power off
  sleep 6
  shot 6-outer-off
  guard 60 xcrun simctl terminate "$udid" com.apple.Preferences
  guard 60 xcrun simctl launch "$udid" com.apple.Preferences
  sleep 10
  shot 6-outer-off-settings
  echo "--- outer on"
  guard 30 xcrun simctl io "$udid" screenConfig --display=primary power on
  sleep 6
  shot 6-outer-on-again
} > "$OUT/screen-power.txt" 2>&1

section "resizable screen"
{
  for geometry in 951x669 669x951 2853x2007 2007x2853@3 1902x1338@2; do
    echo "--- geometry $geometry"
    guard 30 xcrun simctl io "$udid" screenConfig --display=resizable geometry "$geometry"
  done
  echo "--- power on"
  guard 30 xcrun simctl io "$udid" screenConfig --display=resizable power on
  sleep 4
  guard 60 xcrun simctl io "$udid" screenshot --display=resizable "$OUT/7-resizable.png"
  guard 30 xcrun simctl io "$udid" enumerate > "$OUT/7-resizable-displays.txt" 2>&1
} > "$OUT/resizable.txt" 2>&1

section "recorded"
ls -la "$OUT"
for file in help-ui.txt simctl-options.txt inside-simulator.txt simulator-menus-errors.txt simulator-windows.txt \
    menu-candidates.txt menu-clicks.txt 5-rotate-left.txt 5-rotate-right.txt screen-power.txt resizable.txt \
    simulator-app-words.txt words.txt; do
  echo "--- $file"
  head -150 "$OUT/$file"
done
echo "--- simulator-menus.txt"
cat "$OUT/simulator-menus.txt"
exit 0
