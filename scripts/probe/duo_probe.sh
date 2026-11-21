#!/bin/bash
# Temporary. Checks on GitHub's Xcode 27 image that scripts/ci/duo_hinge.m turns
# the hinge of the iPhone Duo simulator. It opens the device flat, then half way,
# then closes it, reads back the angle the device reports at each pose and saves
# what both displays show. Delete this folder and .github/workflows/duo-probe.yml
# once the test workflow opens the device itself.
set -u

: "${SIM_NAME:?}" "${SIM_OS:?}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${GITHUB_WORKSPACE:-$PWD}/out"
HINGE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/duo_hinge"
mkdir -p "$OUT"

# Runs a command and stops it when it takes longer than a number of seconds,
# read from the clock. macOS has no timeout(1).
guard() {
  local seconds=$1 start=$SECONDS pid
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$seconds" ]; then
      echo "stopped after ${seconds}s: $*"
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.25
  done
  wait "$pid"
}

section() { printf '\n=== %s\n' "$*"; }

# The angle the device reports, as "<degrees> valid" or "<degrees> invalid", or
# why it reports none.
reading() {
  guard 30 xcrun simctl spawn "$udid" "$HINGE" angle 2>&1 | head -3 | tr '\n' ' '
}

# Saves what each display shows, and prints the size of each image. A display the
# device is not using is black.
shots() {
  local name=$1 side file
  guard 40 xcrun simctl io "$udid" screenshot --display=primary "$OUT/$name-outer.png" > /dev/null 2>&1
  guard 40 xcrun simctl io "$udid" screenshot --display=primary-1 "$OUT/$name-inner.png" > /dev/null 2>&1
  for side in outer inner; do
    file="$OUT/$name-$side.png"
    if [ -f "$file" ]; then
      echo "$side: $(stat -f %z "$file") bytes," \
        "$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ { printf "%s ", $2 }')pixels"
    else
      echo "$side: no screenshot"
    fi
  done
}

# What devicectl says about the displays, when it answers for a simulator.
panels() {
  local status
  guard 60 xcrun devicectl device info displays --device "$udid" \
    --json-output "$OUT/$1-devicectl.json" > "$OUT/$1-devicectl.txt" 2>&1
  status=$?
  echo "devicectl exit $status"
  head -c 800 "$OUT/$1-devicectl.txt"
  echo
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

section environment
sw_vers | tr '\n' ' '; echo
echo "cores $(sysctl -n hw.ncpu), memory $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
xcodebuild -version | tr '\n' ' '; echo

section boot
began=$SECONDS
xcrun simctl boot "$udid" 2>&1
guard 600 xcrun simctl bootstatus "$udid" -b > "$OUT/bootstatus.txt" 2>&1
echo "bootstatus exit $? after $((SECONDS - began))s"

section displays
began=$SECONDS
guard 300 xcrun simctl io "$udid" enumerate > "$OUT/displays.txt" 2>&1
echo "listed in $((SECONDS - began))s, built-in screens: $(grep -c "Screen Type: Integrated" "$OUT/displays.txt")"

section "build the hinge program"
if ! xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.0-simulator" \
    -fobjc-arc -Wall -Wextra -framework Foundation \
    "$ROOT/scripts/ci/duo_hinge.m" -o "$HINGE" 2>&1; then
  echo "the hinge program did not build"
  exit 1
fi
file "$HINGE"

section "as booted"
echo "angle: $(reading)"
shots booted
panels booted

for degrees in 180 130 0; do
  section "hinge to $degrees degrees"
  began=$SECONDS
  guard 30 xcrun simctl spawn "$udid" "$HINGE" set "$degrees" 2>&1
  echo "set exit $? in $((SECONDS - began))s"
  settled=0
  for tries in $(seq 1 30); do
    sleep 1
    now=$(reading)
    echo "  reading $tries: $now"
    angle=${now%% *}
    if [[ "$now" == *" valid"* ]] &&
        awk -v a="$angle" -v t="$degrees" 'BEGIN { if (a !~ /^[0-9]+([.][0-9]+)?$/) exit 1; d = a - t; exit !(d <= 0.5 && d >= -0.5) }'; then
      settled=$((settled + 1))
      [ "$settled" -ge 2 ] && break
    else
      settled=0
    fi
  done
  if [ "$settled" -ge 2 ]; then
    echo "settled at $degrees degrees"
  else
    echo "did not settle at $degrees degrees"
  fi
  sleep 3
  shots "hinge-$degrees"
  panels "hinge-$degrees"
done

section summary
ls -l "$OUT"
