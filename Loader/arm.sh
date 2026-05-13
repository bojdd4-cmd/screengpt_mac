#!/usr/bin/env bash
# =============================================================================
#  arm.sh — arm DYLD injection for the next launch of LockDown Browser
# =============================================================================
#
#  Sets the launchctl-scope environment variables that cause dyld to load
#  libscreengpt.dylib into LDB the next time it starts.  Also kills any
#  currently-running LDB so the next launch picks up the new env.
#
#  Inverse: ./disarm.sh
#
#  Requires:
#      • SIP disabled  (otherwise launchctl setenv is blocked for some keys)
#      • AMFI disabled (otherwise hardened-runtime LDB ignores DYLD_INSERT)
#      • libscreengpt.dylib already built + deployed by ./build_dylib.sh
#
# =============================================================================

set -euo pipefail

DYLIB_PATH=/usr/local/lib/libscreengpt.dylib
LOG_PATH=/tmp/screengpt_dylib.log

# Target match string — sgpt_should_activate_in_this_process() in the
# dylib compares this case-insensitively against the host's bundle ID
# and executable path.  "LockDownBrowser" matches both bundle ID
# (com.respondus.lockdownbrowser) and exe name (LockDown Browser).
TARGET=LockDownBrowser

clear
echo ""
echo "  +===============================================================+"
echo "  |              ScreenGPT — Arming DYLD injection                |"
echo "  +===============================================================+"
echo ""

# ── 1.  Sanity: dylib exists and is signed ─────────────────────────────────
if [ ! -f "$DYLIB_PATH" ]; then
    echo "  ERROR: $DYLIB_PATH not found."
    echo "  Run ./build_dylib.sh first."
    exit 1
fi
if ! codesign --verify "$DYLIB_PATH" 2>/dev/null; then
    echo "  WARN: $DYLIB_PATH is not signed — attempting ad-hoc resign..."
    codesign --force --sign - "$DYLIB_PATH" || {
        echo "  ERROR: codesign failed.  Re-run ./build_dylib.sh."
        exit 1
    }
fi
echo "  [OK] dylib present + signed: $DYLIB_PATH"

# ── 2.  Pre-flight: SIP + AMFI must be off ─────────────────────────────────
echo ""
echo "  Pre-flight check..."
if csrutil status 2>/dev/null | grep -q "disabled"; then
    echo "  [OK] SIP: disabled"
else
    echo "  [!!] SIP is enabled.  DYLD injection will fail."
    echo "       Boot to Recovery → Terminal → csrutil disable → reboot."
    exit 1
fi
if nvram -p 2>/dev/null | grep -q "amfi_get_out_of_my_way=1"; then
    echo "  [OK] AMFI: disabled"
else
    echo "  [!!] AMFI is enabled.  DYLD injection into hardened-runtime LDB"
    echo "       will be ignored."
    echo "       Run: sudo nvram boot-args=\"amfi_get_out_of_my_way=1\""
    echo "       Then: sudo reboot"
    exit 1
fi

# ── 3.  Set the launchctl-scope env vars ───────────────────────────────────
echo ""
echo "  Setting launchctl env vars..."
launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB_PATH"
launchctl setenv SGPT_TARGET "$TARGET"
echo "  [OK] DYLD_INSERT_LIBRARIES = $DYLIB_PATH"
echo "  [OK] SGPT_TARGET           = $TARGET"

# ── 4.  Kill running LDB so the next launch picks up env ───────────────────
echo ""
echo "  Killing running LDB (if any)..."
killall -9 "LockDown Browser" 2>/dev/null && echo "  [OK] killed LockDown Browser" \
                                          || echo "  [~]  LDB wasn't running"

# ── 5.  Reset the log so this run is isolated ──────────────────────────────
> "$LOG_PATH" 2>/dev/null || true

echo ""
echo "================================================================="
echo "                          ARMED"
echo "================================================================="
echo ""
echo "  Next steps:"
echo "    1. Launch LockDown Browser manually (Applications, Spotlight,"
echo "       LDB.app double-click — whatever you normally do)."
echo "    2. After LDB starts, watch the log to confirm injection:"
echo ""
echo "         tail -f $LOG_PATH"
echo ""
echo "    3. You should see:"
echo "         [date] LOADED  pid=NNNN  bundleID=com.respondus.lockdownbrowser"
echo "                → TARGET MATCH, would init overlay here (Phase 2)"
echo ""
echo "  When done testing:   ./disarm.sh"
echo "================================================================="
echo ""
