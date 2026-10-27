#!/usr/bin/env bash
# Runs the HunchCore test suite reliably on this Mac. Exit code = swift test's exit code.
#
# Root cause of the intermittent "plugin for module 'TestingMacros' not found":
#   * The CLT swift-build (default build system) passes the compiler -load-resolved-plugin for
#     ObservationMacros and SwiftMacros only; the Swift Testing macros live in .../host/plugins/testing/, which
#     it never searches. Xcode toolchains resolve it themselves, hence "works with DEVELOPER_DIR=Xcode-beta".
#   * Package.swift added -load-plugin-library only when it believed the CLT was active, judged from
#     /var/db/xcode_select_link, which here is stale (points at a deleted /Applications/Xcode.app) -> flag
#     dropped. Whether a run passed then depended on which evaluation of the manifest the shared .build had
#     cached (and on other builds sharing that .build), hence "passes with a fresh scratch path".
# Fix: pass the plugin to the compiler explicitly and use a dedicated scratch path, so neither the manifest
# cache nor concurrent dev/release builds in .build can change the outcome. `--build-system native` is not an
# option on the CLT: it cannot find the Testing module at all. Xcode-beta is only a fallback.
set -uo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
PLUGIN=$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
XCODE=/Applications/Xcode-beta.app/Contents/Developer
LOG_DIR=${TMPDIR:-/tmp}/hunch-tests
mkdir -p "$LOG_DIR"

# Builds only the test targets and what they depend on (HunchCoreTests -> HunchCore; HunchTests -> the app
# target, when Tests/HunchTests exists), then runs both suites. Extra script args go to `swift test`
# (e.g. --filter Engine).
TEST_TARGETS=(HunchCoreTests)
[[ -d Tests/HunchTests ]] && TEST_TARGETS+=(HunchTests)
run() { # $1 label, $2 scratch, $3 "clt" to pass the plugin flag, rest: swift test args
  local label=$1 scratch=$2 plugin=$3; shift 3
  local log="$LOG_DIR/$label.log" flags=()
  [[ $plugin == clt ]] && flags=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
  echo "==> swift test via $label (scratch $scratch, log $log)"
  {
    local t
    for t in "${TEST_TARGETS[@]}"; do
      swift build --scratch-path "$scratch" --target "$t" ${flags[@]+"${flags[@]}"} || exit 1
    done
    swift test --skip-build --scratch-path "$scratch" ${flags[@]+"${flags[@]}"} "$@"
  } 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

if [[ -z ${DEVELOPER_DIR:-} && -f $PLUGIN ]]; then
  export DEVELOPER_DIR=$CLT
  run clt .build/test-clt clt "$@"
  status=$?
  if (( status != 0 )) && grep -q "plugin for module 'TestingMacros' not found" "$LOG_DIR/clt.log" && [[ -d $XCODE ]]; then
    echo "==> CLT could not load TestingMacros; falling back to Xcode-beta"
    export DEVELOPER_DIR=$XCODE
    run xcode-beta .build/test-xcode none "$@"
    status=$?
  fi
else
  # Respect an explicit DEVELOPER_DIR (e.g. Xcode-beta), which finds its own plugins.
  run developer-dir .build/test-devdir none "$@"
  status=$?
fi
echo "==> toolchain: DEVELOPER_DIR=$DEVELOPER_DIR -> exit $status"
exit "$status"
