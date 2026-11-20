#!/bin/bash
# Builds the VoiceType scheme for an iOS simulator, runs both test bundles on it,
# and gathers the logs and the snapshot images the tests write.
#
# usage: run_ios_tests.sh build | test | collect | screenshot
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

  # One line per XCTest case and per Swift Testing test or suite.
  grep -E "Test Case .* (passed|failed) \(|(passed|failed|skipped) after [0-9.]+ seconds" \
    "$OUT/test.log" > "$OUT/tests.txt"
  echo "test-without-building exit $status," \
    "$(grep -c "passed" "$OUT/tests.txt") lines report a pass," \
    "$(grep -c "failed" "$OUT/tests.txt") a failure"
  grep -E "Test Case .* failed|failed after|recorded an issue|: error: |Executed [0-9]+ tests?|Test run with|\*\* TEST|Testing failed|Failing tests" \
    "$OUT/test.log" | sed "s|$SRC/||" | head -200
  if [ "$status" -ne 0 ]; then
    echo "--- last lines of the test log"
    tail -n 40 "$OUT/test.log"
  fi
  return "$status"
}

collect() {
  # The snapshot tests write their images into the test host's temporary folder,
  # which is inside the simulator's data folder on this machine.
  mkdir -p "$OUT/snaps" "$OUT/keyboard-snaps"
  local root
  for root in "$HOME/Library/Developer/CoreSimulator/Devices" "$HOME/Library/Developer/XCTestDevices"; do
    [ -d "$root" ] || continue
    find "$root" -type f -name 'voicetype-*.png' -exec cp -f {} "$OUT/snaps/" \; 2>/dev/null
    find "$root" -type f -name 'keyboard-*.png' -exec cp -f {} "$OUT/keyboard-snaps/" \; 2>/dev/null
  done
  echo "app images: $(find "$OUT/snaps" -name '*.png' | wc -l | tr -d ' ')," \
    "keyboard images: $(find "$OUT/keyboard-snaps" -name '*.png' | wc -l | tr -d ' ')"

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

# Launches the built app in the simulator and saves what the screen shows. Without
# an account that is the sign-in page, in the window the system gives the app.
screenshot() {
  local udid app
  udid=$(cat "$OUT/simulator-udid.txt" 2>/dev/null)
  app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/VoiceType.app"
  if [ -z "$udid" ] || [ ! -d "$app" ]; then
    echo "no built app to launch"
    return 0
  fi
  xcrun simctl help > "$OUT/simctl-help.txt" 2>&1
  xcrun simctl help io > "$OUT/simctl-io-help.txt" 2>&1
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl io "$udid" enumerate > "$OUT/simulator-displays.txt" 2>&1
  xcrun simctl install "$udid" "$app"
  xcrun simctl launch "$udid" "$BUNDLE_ID"
  sleep 12
  xcrun simctl io "$udid" screenshot "$OUT/launch.png"
}

case "${1:-}" in
  build) build ;;
  test) run_tests ;;
  collect) collect ;;
  screenshot) screenshot ;;
  *)
    echo "usage: $0 build | test | collect | screenshot" >&2
    exit 64
    ;;
esac
