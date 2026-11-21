#!/bin/bash
# Builds the VoiceType scheme for an iOS simulator, runs both test bundles on it,
# and gathers the logs, the snapshot images the tests write and screenshots of
# the simulator's display. On an iPhone Duo it also opens the device and shows the
# pages on the inner display.
#
# usage: run_ios_tests.sh build | test | collect | screenshot | onscreen | unfolded open | unfolded half-open
#
# Read from the environment:
#   SIM_NAME  simulator device name, for example "iPhone 17"
#   SIM_OS    iOS version of that simulator, for example "26.2"
#   SRC       folder that holds VoiceType.xcodeproj (default: $GITHUB_WORKSPACE/src)
#   OUT       folder for logs, results and images (default: $GITHUB_WORKSPACE/out)
set -u -o pipefail

: "${SIM_NAME:?}" "${SIM_OS:?}"
SRC="${SRC:-${GITHUB_WORKSPACE:?}/src}"
OUT="${OUT:-${GITHUB_WORKSPACE:?}/out}"
WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/voicetype-ios-tests"
DERIVED_DATA="$WORK/dd"
RESULT_BUNDLE="$WORK/result.xcresult"
BUNDLE_ID="com.kyleqi.voicetype"
mkdir -p "$OUT" "$WORK"

# Prints the UDID of the simulator named SIM_NAME on iOS SIM_OS. Two runtimes can
# each have a device with the same name, so the name alone does not identify one.
find_simulator() {
  xcrun simctl list devices available | awk -v section="-- iOS $SIM_OS --" -v prefix="    $SIM_NAME (" '
    /^-- / { inside = ($0 == section) }
    inside && index($0, prefix) == 1 {
      rest = substr($0, length(prefix) + 1)
      print substr(rest, 1, index(rest, ")") - 1)
      exit
    }'
}

# Runs a command and stops it when it takes longer than a number of seconds.
# macOS has no timeout(1), and simctl can wait for a simulator without end. The
# time is read from the clock: on a busy machine each short sleep below can take
# much longer than it asks for.
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

# How many built-in screens the simulator has, once known: 2 for an iPhone Duo,
# whose outer and inner displays are separate screens, 1 for other iPhones.
DISPLAYS=""

# Counts the simulator's built-in screens into DISPLAYS. Listing them has taken
# minutes while a test was starting, so each step counts them before it starts
# anything, and the count is kept in a file for the steps after it.
count_displays() {
  local udid=$1 count
  [ -n "$DISPLAYS" ] && return 0
  if [ -s "$OUT/simulator-display-count.txt" ]; then
    DISPLAYS=$(cat "$OUT/simulator-display-count.txt")
    return 0
  fi
  guard 180 xcrun simctl io "$udid" enumerate > "$OUT/simulator-displays.txt" 2>&1
  count=$(grep -c "Screen Type: Integrated" "$OUT/simulator-displays.txt")
  if [ "${count:-0}" -gt 0 ]; then
    DISPLAYS=$count
    echo "$count" > "$OUT/simulator-display-count.txt"
  fi
  echo "built-in screens: ${DISPLAYS:-not known}"
}
# The last screenshot saved of each screen of an iPhone Duo, and the screens that
# showed the same image twice in a row.
LAST_OUTER=""
LAST_INNER=""
UNCHANGING=""

# Saves one screen of an iPhone Duo as <path>-<side>.png. The display the device
# is not using stays black, so a screen that shows the same image twice in a row
# is left out from then on.
shoot_side() {
  local udid=$1 screen=$2 side=$3 path=$4 seconds=$5 file last
  file="$path-$side.png"
  case " $UNCHANGING " in *" $side "*) return 0 ;; esac
  if ! guard "$seconds" xcrun simctl io "$udid" screenshot "--display=$screen" "$file"; then
    rm -f "$file"
    return 0
  fi
  if [ "$side" = outer ]; then
    last=$LAST_OUTER
    LAST_OUTER=$file
  else
    last=$LAST_INNER
    LAST_INNER=$file
  fi
  if [ -n "$last" ] && cmp -s "$last" "$file"; then
    echo "the $side display shows the same image as before and is left out from here on"
    UNCHANGING="$UNCHANGING $side"
  fi
}

# Saves what the simulator's display shows as <path>.png. simctl has to be told
# which screen of an iPhone Duo to save, so both are saved there, as
# <path>-outer.png and <path>-inner.png. The third argument is the longest one
# screenshot may take, in seconds.
shoot() {
  local udid=$1 path=$2 seconds=${3:-60}
  count_displays "$udid"
  if [ "${DISPLAYS:-0}" -ge 2 ]; then
    shoot_side "$udid" primary outer "$path" "$seconds"
    shoot_side "$udid" primary-1 inner "$path" "$seconds"
  elif ! guard "$seconds" xcrun simctl io "$udid" screenshot "$path.png"; then
    rm -f "$path.png"
  fi
}

build() {
  {
    sw_vers | tr '\n' ' '; echo
    echo "cores $(sysctl -n hw.ncpu), memory $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
    xcodebuild -version | tr '\n' ' '; echo
    xcrun swiftc --version 2>&1 | head -1
    echo "sources $(git -C "$SRC" rev-parse HEAD) $(git -C "$SRC" log -1 --format=%s)"
  } | tee "$OUT/environment.txt"
  xcrun simctl list devices available > "$OUT/simulators.txt" 2>&1

  local udid
  udid=$(find_simulator)
  if [ -z "$udid" ]; then
    echo "No simulator named '$SIM_NAME' on iOS $SIM_OS. Available:"
    cat "$OUT/simulators.txt"
    return 1
  fi
  echo "$udid" > "$OUT/simulator-udid.txt"
  echo "simulator $SIM_NAME, iOS $SIM_OS, $udid" | tee -a "$OUT/environment.txt"

  xcodebuild build-for-testing \
    -project "$SRC/VoiceType.xcodeproj" -scheme VoiceType \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED_DATA" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    > "$OUT/build.log" 2>&1
  local status=$?

  grep -E "(error|warning): " "$OUT/build.log" | sort -u > "$OUT/build-diagnostics.txt"
  echo "build-for-testing exit $status," \
    "$(grep -c "error: " "$OUT/build-diagnostics.txt") distinct errors," \
    "$(grep -c "warning: " "$OUT/build-diagnostics.txt") distinct warnings"
  grep "error: " "$OUT/build-diagnostics.txt" | sed "s|$SRC/||" | head -100
  echo "warnings in this project's sources:"
  grep "warning: " "$OUT/build-diagnostics.txt" | grep -F "$SRC/" | sed "s|$SRC/||" | head -60
  if [ "$status" -ne 0 ]; then
    echo "--- last lines of the build log"
    tail -n 60 "$OUT/build.log"
  fi
  return "$status"
}

run_tests() {
  local udid
  udid=$(cat "$OUT/simulator-udid.txt") || return 1
  rm -rf "$RESULT_BUNDLE"

  xcodebuild test-without-building \
    -project "$SRC/VoiceType.xcodeproj" -scheme VoiceType \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$RESULT_BUNDLE" \
    > "$OUT/test.log" 2>&1
  local status=$?

  # One line per XCTest case and per Swift Testing test or suite. The result is
  # matched where each kind of line states it, since test names contain the
  # words "passed" and "failed" too.
  grep -E "Test Case .* (passed|failed) \(|(passed|failed|skipped) after [0-9.]+ seconds" \
    "$OUT/test.log" > "$OUT/tests.txt"
  echo "test-without-building exit $status," \
    "$(grep -c -E "' passed \(|passed after [0-9.]+ seconds" "$OUT/tests.txt") lines report a pass," \
    "$(grep -c -E "' failed \(|failed after [0-9.]+ seconds" "$OUT/tests.txt") a failure"
  grep -E "Test Case .*' failed \(|failed after [0-9.]+ seconds|recorded an issue|: error: |Executed [0-9]+ tests?|Test run with|\*\* TEST|Testing failed|Failing tests" \
    "$OUT/test.log" | sed "s|$SRC/||" | head -200
  if [ "$status" -ne 0 ]; then
    echo "--- last lines of the test log"
    tail -n 40 "$OUT/test.log"
  fi
  return "$status"
}

collect() {
  # The snapshot tests write their images into the test host's temporary folder,
  # which is inside the simulator's data folder on this machine. Next to them is
  # the tests' report on the scene the system gave the app.
  mkdir -p "$OUT/snaps" "$OUT/keyboard-snaps"
  local root report
  for root in "$HOME/Library/Developer/CoreSimulator/Devices" "$HOME/Library/Developer/XCTestDevices"; do
    [ -d "$root" ] || continue
    find "$root" -type f -name 'voicetype-*.png' -exec cp -f {} "$OUT/snaps/" \; 2>/dev/null
    find "$root" -type f -name 'voicetype-scene*.txt' -exec cp -f {} "$OUT/snaps/" \; 2>/dev/null
    find "$root" -type f -name 'keyboard-*.png' -exec cp -f {} "$OUT/keyboard-snaps/" \; 2>/dev/null
  done
  echo "app images: $(find "$OUT/snaps" -name '*.png' | wc -l | tr -d ' ')," \
    "keyboard images: $(find "$OUT/keyboard-snaps" -name '*.png' | wc -l | tr -d ' ')"
  for report in "$OUT"/snaps/voicetype-scene*.txt; do
    [ -f "$report" ] || continue
    echo "--- the scene the tests ran in ($(basename "$report"))"
    cut -c1-400 "$report"
  done

  if [ ! -d "$RESULT_BUNDLE" ]; then
    echo "no result bundle"
    return 0
  fi
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" \
    > "$OUT/summary.json" 2> "$OUT/xcresulttool.log"
  xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" \
    > "$OUT/tests.json" 2>> "$OUT/xcresulttool.log"
  tar -czf "$OUT/result.xcresult.tar.gz" -C "$(dirname "$RESULT_BUNDLE")" "$(basename "$RESULT_BUNDLE")"
  grep -E '"(result|totalTestCount|passedTests|failedTests|skippedTests|expectedFailures|testName|failureText)"' \
    "$OUT/summary.json" | head -80
  return 0
}

# Launches the built app in the simulator and saves what the display shows. Without
# an account that is the sign-in page, in the window the system gives the app. The
# simulator stays booted for the step that follows.
screenshot() {
  local udid app
  udid=$(cat "$OUT/simulator-udid.txt" 2>/dev/null)
  app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/VoiceType.app"
  if [ -z "$udid" ] || [ ! -d "$app" ]; then
    echo "no built app to launch"
    return 0
  fi
  # bootstatus has reported a failed data migration for a simulator that then
  # ran the app, so what it returns does not end this step.
  guard 240 xcrun simctl bootstatus "$udid" -b
  count_displays "$udid"
  guard 300 xcrun simctl install "$udid" "$app"
  guard 120 xcrun simctl launch "$udid" "$BUNDLE_ID"
  sleep 12
  shoot "$udid" "$OUT/launch"
}

# Runs the one test that lays the pages out in the simulator's own scene, first as
# the simulator stands and then turned to landscape, and takes a screenshot of the
# display while each page is up. The test says that a page is up by writing a file
# into its temporary folder, then waits for the answer written here. Unlike the
# images the tests render themselves, a screenshot shows the status bar and
# everything else the system draws around the app. The screenshots and the pages
# the test rendered go into $OUT/<folder>, the test's log into $OUT/<folder>.log.
show_pages() {
  local udid=$1 folder=$2 containers pid status marker name seen=" " began
  # The test host's temporary folder is in its data container on this machine.
  containers="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Data/Application"
  mkdir -p "$OUT/$folder/rendered"
  # Files an earlier run left there would be taken for this run's.
  find "$containers" -maxdepth 4 -type f \( -name 'voicetype-scene*' -o -name 'voicetype-onscreen-*' \) \
    -delete 2>/dev/null
  count_displays "$udid"
  # Every run starts with screenshots of both screens of an iPhone Duo.
  LAST_OUTER=""
  LAST_INNER=""
  UNCHANGING=""

  # xcodebuild hands a variable named TEST_RUNNER_<name> to the tests as <name>.
  # The test waits this long for an answer at most: longer than one screenshot of
  # each of two screens may take below.
  TEST_RUNNER_UI_ON_SCREEN_SECONDS=90 TEST_RUNNER_UI_TURN_SCENE=1 xcodebuild test-without-building \
    -project "$SRC/VoiceType.xcodeproj" -scheme VoiceType \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:VoiceTypeTests/HomeSnapshotTests/testCaptureAtSceneSize \
    > "$OUT/$folder.log" 2>&1 &
  pid=$!

  began=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - began)) -ge 900 ]; then
      echo "stopped the on-screen run after $((SECONDS - began)) seconds"
      kill -9 "$pid" 2>/dev/null
      break
    fi
    while IFS= read -r marker <&3; do
      name=$(basename "$marker" .marker)
      name=${name#voicetype-onscreen-}
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      # Lets the display catch up with the page before the screenshot.
      sleep 1
      shoot "$udid" "$OUT/$folder/$name" 30
      : > "${marker%.marker}.done"
    done 3< <(find "$containers" -maxdepth 4 -name 'voicetype-onscreen-*.marker' 2>/dev/null)
    sleep 0.5
  done
  wait "$pid"
  status=$?

  # What this run rendered itself: the same pages without the system's drawing,
  # and the tests' reports on the scene in both orientations.
  find "$containers" -maxdepth 4 -type f \( -name 'voicetype-scene*.png' -o -name 'voicetype-scene*.txt' \) \
    -exec cp -f {} "$OUT/$folder/rendered/" \; 2>/dev/null
  grep -E "Test Case .* (passed|failed) \(|\*\* TEST|: error: |UI_SCENE " "$OUT/$folder.log" |
    sed "s|$SRC/||" | cut -c1-400 | head -80
  echo "on-screen run exit $status," \
    "screenshots: $(find "$OUT/$folder" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')," \
    "pages the test rendered: $(find "$OUT/$folder/rendered" -name '*.png' | wc -l | tr -d ' ')"
  if [ "$status" -ne 0 ]; then
    echo "--- last lines of the on-screen log"
    tail -n 40 "$OUT/$folder.log"
  fi
  return "$status"
}

onscreen() {
  local udid
  udid=$(cat "$OUT/simulator-udid.txt" 2>/dev/null)
  if [ -z "$udid" ] || [ ! -d "$DERIVED_DATA/Build/Products" ]; then
    echo "nothing built to run"
    return 0
  fi
  show_pages "$udid" onscreen
}

# The program that turns the hinge of an iPhone Duo, built from duo_hinge.m.
HINGE="$WORK/duo_hinge"

# Saves what each of the two screens of an iPhone Duo shows, as <path>-outer.png
# and <path>-inner.png, also when a screen shows what it showed before.
shoot_both() {
  local udid=$1 path=$2
  guard 30 xcrun simctl io "$udid" screenshot --display=primary "$path-outer.png" || rm -f "$path-outer.png"
  guard 30 xcrun simctl io "$udid" screenshot --display=primary-1 "$path-inner.png" || rm -f "$path-inner.png"
}

# Prints the hinge angle the device reports, as "<degrees> valid" or "<degrees>
# invalid", or why it reports none.
hinge_angle() {
  guard 30 xcrun simctl spawn "$1" "$HINGE" angle 2>&1 | head -3 | tr '\n' ' '
}

# Opens an iPhone Duo to a pose and shows the pages there: "open" lays it flat,
# and "half-open" holds it at 130 degrees, the angle of Simulator's Book preset.
# The app is on the screen when the hinge turns, the way someone opens the phone
# while using it, and both screens are saved before and after. A simulator with
# one screen has no hinge, and the step ends there.
unfolded() {
  local pose=${1:-} degrees udid app reading angle tries settled=0
  case "$pose" in
    open) degrees=180 ;;
    half-open) degrees=130 ;;
    *)
      echo "usage: $0 unfolded open | half-open" >&2
      return 64
      ;;
  esac
  udid=$(cat "$OUT/simulator-udid.txt" 2>/dev/null)
  app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/VoiceType.app"
  if [ -z "$udid" ] || [ ! -d "$app" ]; then
    echo "nothing built to run"
    return 0
  fi
  guard 240 xcrun simctl bootstatus "$udid" -b
  count_displays "$udid"
  if [ "${DISPLAYS:-0}" -lt 2 ]; then
    echo "this simulator has one screen and no hinge"
    return 0
  fi

  if [ ! -x "$HINGE" ]; then
    if ! xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.0-simulator" \
        -fobjc-arc -Wall -Wextra -framework Foundation \
        "$SRC/scripts/ci/duo_hinge.m" -o "$HINGE" > "$OUT/duo-hinge-build.log" 2>&1; then
      echo "the hinge program did not build:"
      cat "$OUT/duo-hinge-build.log"
      return 1
    fi
  fi
  mkdir -p "$OUT/$pose"

  guard 120 xcrun simctl launch "$udid" "$BUNDLE_ID"
  sleep 8
  shoot_both "$udid" "$OUT/$pose/before"
  echo "before: $(hinge_angle "$udid")" > "$OUT/$pose/hinge.txt"
  if ! guard 30 xcrun simctl spawn "$udid" "$HINGE" set "$degrees" >> "$OUT/$pose/hinge.txt" 2>&1; then
    cat "$OUT/$pose/hinge.txt"
    echo "the hinge could not be set to $degrees degrees"
    return 1
  fi
  # The device reports the angle while the hinge moves. The pose has settled once
  # two readings in a row are within half a degree of it.
  for tries in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    sleep 1
    reading=$(hinge_angle "$udid")
    echo "reading $tries: $reading" >> "$OUT/$pose/hinge.txt"
    angle=${reading%% *}
    if [[ "$reading" == *" valid"* ]] &&
        awk -v a="$angle" -v t="$degrees" 'BEGIN { if (a !~ /^[0-9]+([.][0-9]+)?$/) exit 1; d = a - t; exit !(d <= 0.5 && d >= -0.5) }'; then
      settled=$((settled + 1))
      [ "$settled" -ge 2 ] && break
    else
      settled=0
    fi
  done
  cat "$OUT/$pose/hinge.txt"
  if [ "$settled" -ge 2 ]; then
    echo "the hinge is at $degrees degrees"
  else
    echo "the device did not report the hinge at $degrees degrees; the screenshots show where the app went"
  fi
  # Lets the app move to the other screen and lay itself out there.
  sleep 5
  shoot_both "$udid" "$OUT/$pose/after"
  show_pages "$udid" "onscreen-$pose"
}

case "${1:-}" in
  build) build ;;
  test) run_tests ;;
  collect) collect ;;
  screenshot) screenshot ;;
  onscreen) onscreen ;;
  unfolded) unfolded "${2:-}" ;;
  *)
    echo "usage: $0 build | test | collect | screenshot | onscreen | unfolded open | unfolded half-open" >&2
    exit 64
    ;;
esac
