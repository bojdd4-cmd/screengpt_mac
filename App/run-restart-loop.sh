#!/usr/bin/env bash
# =============================================================================
#  run-restart-loop.sh
#  ---------------------------------------------------------------------------
#  DEATH-PATTERN TEST.  Repeatedly launches the .app bundle in a loop so we
#  can see how LDB kills us during an exam:
#
#    • If LDB kills us ONCE at exam start, the wrapper restarts within 1 s
#      and we stay alive for the rest of the exam → auto-restart works.
#
#    • If LDB kills us REPEATEDLY (every few seconds throughout the exam),
#      we'll see a long stream of "launch #N / died" pairs in restart.log.
#      That means auto-restart isn't enough and we need an architecture
#      pivot.
#
#  Run from inside ~/Downloads/screengpt_mac/App :
#      chmod +x run-restart-loop.sh
#      ./run-restart-loop.sh
#
#  Stop with Ctrl+C.
#
#  Log file:  ~/Library/Logs/Color Calibration/restart.log
#
#  WARNING: this file embeds your credentials below.  Don't commit it to
#  any public repo as-is.  Production builds use the SwiftUI login screen
#  (week 3) — this is a week-2 diagnostic only.
# =============================================================================

set -u

# Resolve script directory so paths work regardless of where it's invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BINARY="$SCRIPT_DIR/build/ColorCalibration.app/Contents/MacOS/ColorCalibration"
LOG_DIR="$HOME/Library/Logs/Color Calibration"
RESTART_LOG="$LOG_DIR/restart.log"

# Sanity check — the .app must exist.  If not, point at the build script.
if [ ! -x "$APP_BINARY" ]; then
    echo "❌  Binary not found at:"
    echo "    $APP_BINARY"
    echo ""
    echo "Build the .app bundle first:"
    echo "    ./scripts/build_app.sh"
    exit 1
fi

mkdir -p "$LOG_DIR"

# Clean Ctrl+C handling so we can stop the loop without an ugly traceback.
trap 'echo ""; echo "═══ Stopped after $N launches ═══"; exit 0' INT

N=0
echo "═══ Starting restart-loop test ═══"
echo "  binary:  $APP_BINARY"
echo "  log:     $RESTART_LOG"
echo "  Ctrl+C to stop."
echo ""

while true; do
    N=$((N + 1))
    ts="$(date +%H:%M:%S)"
    msg="=== launch #$N at $ts ==="
    echo "$msg"
    echo "$msg" >> "$RESTART_LOG"

    # Launch the .app bundle's executable directly so env vars propagate.
    # If you want to swap credentials, edit them here:
    CALIB_EMAIL="tidepodgoat@gmail.com" \
    CALIB_PASSWORD="bodavis55" \
    CALIB_DIAGNOSTICS=1 \
        "$APP_BINARY"

    EC=$?
    ts="$(date +%H:%M:%S)"
    msg="=== died with exit $EC at $ts ==="
    echo "$msg"
    echo "$msg" >> "$RESTART_LOG"
    echo ""

    # 1-second backoff prevents tight loops when something is fundamentally
    # broken (e.g. binary crashes on launch).  LDB can kill us within
    # milliseconds of exec, so this rate limits us to ~30 launches/minute.
    sleep 1
done
