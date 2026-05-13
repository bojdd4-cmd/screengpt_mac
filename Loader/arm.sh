#!/usr/bin/env bash
# =============================================================================
#  arm.sh — arm + launch LDB with DYLD injection inline
# =============================================================================
#
#  Modern macOS (Sonoma+ / Tahoe) silently blocks `launchctl setenv` for
#  security-sensitive keys like DYLD_INSERT_LIBRARIES — setenv "succeeds"
#  but the value never persists.  Apple's hardening against runtime
#  injection via launchd session env.
#
#  Workaround: directly exec LockDown Browser from this script with the
#  env vars set INLINE in the exec context.  POSIX env inheritance still
#  works — LDB sees DYLD_INSERT_LIBRARIES because it was its parent
#  shell's environment, and dyld (with AMFI off) loads our dylib into
#  the new LDB process.
#
#  Inverse: ./disarm.sh   (kills LDB, that's all we need now)
#
#  Requires:
#      • SIP disabled
#      • AMFI disabled (boot-arg amfi_get_out_of_my_way=1)
#      • libscreengpt.dylib built + deployed by ./build_dylib.sh
#
# =============================================================================

set -euo pipefail

DYLIB_PATH=/usr/local/lib/libscreengpt.dylib
LOG_PATH=/tmp/screengpt_dylib.log
LDB_APP="/Applications/LockDown Browser.app"
LDB_EXE="$LDB_APP/Contents/MacOS/LockDown Browser"
TARGET=LockDownBrowser

clear
echo ""
echo "  +===============================================================+"
echo "  |        ScreenGPT — Arming + launching LDB with injection      |"
echo "  +===============================================================+"
echo ""

# ── 1.  Sanity ─────────────────────────────────────────────────────────────
if [ ! -f "$DYLIB_PATH" ]; then
    echo "  ERROR: $DYLIB_PATH not found."
    echo "  Run ./build_dylib.sh first."
    exit 1
fi
if ! codesign --verify "$DYLIB_PATH" 2>/dev/null; then
    echo "  WARN: dylib not signed, ad-hoc resigning..."
    codesign --force --sign - "$DYLIB_PATH" || {
        echo "  ERROR: codesign failed."; exit 1
    }
fi
echo "  [OK] dylib: $DYLIB_PATH"

if [ ! -d "$LDB_APP" ]; then
    echo "  ERROR: LockDown Browser not found at $LDB_APP"
    echo "  Install LDB before running this script."
    exit 1
fi
echo "  [OK] LDB:   $LDB_APP"

# ── 2.  SIP + AMFI ─────────────────────────────────────────────────────────
echo ""
echo "  Pre-flight..."
if csrutil status 2>/dev/null | grep -q "disabled"; then
    echo "  [OK] SIP disabled"
else
    echo "  [!!] SIP enabled — injection will fail."
    echo "       Boot Recovery → csrutil disable → reboot"
    exit 1
fi
if nvram -p 2>/dev/null | grep -q "amfi_get_out_of_my_way=1"; then
    echo "  [OK] AMFI disabled"
else
    echo "  [!!] AMFI enabled — dyld will ignore DYLD_INSERT_LIBRARIES on LDB."
    echo "       sudo nvram boot-args=\"amfi_get_out_of_my_way=1\" && sudo reboot"
    exit 1
fi

# ── 3.  Kill running LDB so we can launch fresh ────────────────────────────
echo ""
echo "  Killing running LDB (if any)..."
killall -9 "LockDown Browser" 2>/dev/null && echo "  [OK] killed LockDown Browser" \
                                          || echo "  [~]  LDB wasn't running"
# Give macOS a moment to fully terminate helpers + release ports
sleep 1

# ── 4.  Reset log so this run is isolated ──────────────────────────────────
> "$LOG_PATH" 2>/dev/null || true

# ── 5.  Launch LDB inline with DYLD env in our exec context ───────────────
#
# Why this works when launchctl setenv doesn't: macOS blocks
# launchctl setenv DYLD_* as hardening, BUT the POSIX env inheritance
# from a shell to its exec'd child is unrestricted.  We set the env
# variables in THIS shell's environment, then exec LDB — LDB inherits
# them as part of its initial env block, and dyld (with AMFI off)
# honors them.
#
# We use `nohup ... &` + `disown` so:
#   • LDB runs detached from this shell (closes Terminal → LDB lives)
#   • Output goes to /dev/null (no terminal pollution)
#   • Our shell can exit immediately
echo ""
echo "  Launching LDB with injection..."
echo "    DYLD_INSERT_LIBRARIES = $DYLIB_PATH"
echo "    SGPT_TARGET           = $TARGET"
echo ""

DYLD_INSERT_LIBRARIES="$DYLIB_PATH" \
SGPT_TARGET="$TARGET" \
nohup "$LDB_EXE" >/dev/null 2>&1 &
LDB_PID=$!
disown 2>/dev/null || true

# Brief settle
sleep 1

if kill -0 "$LDB_PID" 2>/dev/null; then
    echo "  [OK] LDB launched, pid=$LDB_PID"
else
    echo "  [!!] LDB did not stay alive — check $LOG_PATH"
fi

echo ""
echo "================================================================="
echo "                    LAUNCHED + ARMED"
echo "================================================================="
echo ""
echo "  Watch the injection live:"
echo "    tail -f $LOG_PATH"
echo ""
echo "  Look for:"
echo "    [time] LOADED  pid=$LDB_PID  bundleID=com.Respondus.LockDownBrowser"
echo "           hooked NSWorkspace.runningApplications"
echo "           (and other hooks)"
echo ""
echo "  When done:  ./disarm.sh"
echo "================================================================="
echo ""
