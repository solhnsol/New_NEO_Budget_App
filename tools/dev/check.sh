#!/bin/zsh
# Fast verification during development. Prints how long each phase took, shows only errors and the test summary, and keeps full logs.
#
#   tools/dev/check.sh pkg [filter]          Swift package tests (NEOBudgetCore/Calendar/...). A filter is a Swift Testing / XCTest name regex.
#   tools/dev/check.sh app                   iOS app: build + ALL app tests (about 15 s warm).
#   tools/dev/check.sh app --file Name       iOS app: build + only the tests in OnAllAppTests/<Name>.swift (e.g. DayContentLayoutTests).
#   tools/dev/check.sh app testName() ...    iOS app: build + only these tests (as xcodebuild -only-testing names).
#   tools/dev/check.sh build                 iOS app: compile only (no tests), for a quick type check.
#   tools/dev/check.sh ui [launch args...]   build, install and launch on the simulator with launch args (default: -demo), then screenshot.
#   tools/dev/check.sh full                  everything: package tests + all app tests. Run before merging, not after each edit.
#
# One derived-data folder and one simulator are reused; nothing is cleaned. Set CHECK_TIMEOUT (seconds, default 600) to bound a run.
set -u
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT=${0:A:h:h:h}
APPDIR=$ROOT/Platform/iOS/OnAllApp
SIM=${SIM:-E72C623A-60D2-4052-B1D4-64A7E33E34AB}        # iPhone 18 Pro; find yours with `xcrun simctl list devices`
DD=${DD:-${TMPDIR:-/tmp}/onall-dd}
LOGS=${LOGS:-${TMPDIR:-/tmp}/onall-check-logs}
BID=dev.onall.app
LIMIT=${CHECK_TIMEOUT:-600}
mkdir -p $LOGS
DEST="platform=iOS Simulator,id=$SIM"

phase() {   # phase "label" logfile command...   (prints seconds, and the errors/summary or the log tail on failure)
  local label=$1 log=$2; shift 2
  local start=$SECONDS
  "$@" > $log 2>&1 &                                  # bounded by a watchdog: a hung run is cut off, not waited on
  local pid=$!
  ( sleep $LIMIT; kill $pid 2>/dev/null; sleep 2; kill -9 $pid 2>/dev/null ) > /dev/null 2>&1 &
  local dog=$!
  wait $pid
  local rc=$?
  kill $dog 2>/dev/null; wait $dog 2>/dev/null
  (( rc == 143 || rc == 137 )) && echo "timed out after ${LIMIT}s"
  printf '%-34s %4ds  (rc=%d)\n' "$label" $(( SECONDS - start )) $rc
  grep -E "error:|Test run with|✘|TEST (SUCCEEDED|FAILED)|BUILD (SUCCEEDED|FAILED)|Executed [0-9]+ tests" $log | sort -u | cut -c1-220 | head -25
  if (( rc != 0 )); then echo "--- tail of $log"; tail -15 $log | cut -c1-200; fi
  return $rc
}

booted() { xcrun simctl list devices booted | grep -q "$SIM"; }
ensure_sim() { booted || { echo "booting simulator $SIM"; xcrun simctl boot $SIM; xcrun simctl bootstatus $SIM -b > /dev/null 2>&1; } }

xb() { ( cd $APPDIR && xcodebuild "$@" -scheme OnAllApp -destination "$DEST" -derivedDataPath $DD ) }

# Test names from a file: every `@Test ... func name(label:)` becomes -only-testing:OnAllAppTests/name(label:).
names_in() {
  python3 - "$APPDIR/OnAllAppTests/$1.swift" <<'PY'
import re, sys
text = open(sys.argv[1]).read().splitlines()
for i, line in enumerate(text):
    if "@Test" not in line: continue
    for j in range(i, min(i + 3, len(text))):
        m = re.search(r'func\s+(\w+)\s*\(([^)]*)\)', text[j])
        if m:
            labels = [p.strip().split(':')[0].split()[0] for p in m.group(2).split(',') if p.strip()]
            print(f"OnAllAppTests/{m.group(1)}({''.join(l + ':' for l in labels)})")
            break
PY
}

cmd=${1:-app}; shift 2>/dev/null
total=$SECONDS
case $cmd in
  pkg)
    filt=(); [[ -n ${1:-} ]] && filt=(--filter "$1")
    phase "swift test ${1:-(all)}" $LOGS/pkg.log swift test --package-path $ROOT "${filt[@]}" ;;
  build)
    phase "xcodebuild build" $LOGS/build.log xb build ;;
  app)
    ensure_sim
    only=()
    if [[ ${1:-} == --file ]]; then
      for n in $(names_in "$2"); do only+=(-only-testing:"$n"); done
      (( ${#only} )) || { echo "no @Test functions found in OnAllAppTests/$2.swift"; exit 2 }
    else
      for n in "$@"; do only+=(-only-testing:OnAllAppTests/$n); done
    fi
    phase "xcodebuild build-for-testing" $LOGS/bft.log xb build-for-testing || exit 1
    phase "xcodebuild test-without-building" $LOGS/twb.log xb test-without-building ${only[@]} ;;
  ui)
    ensure_sim
    args=("$@"); (( ${#args} )) || args=(-demo)
    phase "xcodebuild build" $LOGS/build.log xb build || exit 1
    APP=$DD/Build/Products/Debug-iphonesimulator/OnAllApp.app
    xcrun simctl terminate $SIM $BID 2>/dev/null
    phase "install + launch" $LOGS/launch.log sh -c "xcrun simctl install $SIM '$APP' && xcrun simctl launch $SIM $BID ${args[*]}"
    sleep 2
    xcrun simctl io $SIM screenshot $LOGS/screen.png > /dev/null 2>&1 && echo "screenshot: $LOGS/screen.png" ;;
  full)
    $0 pkg && $0 app ;;
  *)
    sed -n 2,12p $0; exit 2 ;;
esac
echo "total: $(( SECONDS - total ))s   logs: $LOGS"
