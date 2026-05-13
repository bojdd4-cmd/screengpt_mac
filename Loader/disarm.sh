#!/usr/bin/env bash
# =============================================================================
#  disarm.sh — kill the injected LDB session
# =============================================================================
#
#  Since arm.sh now launches LDB directly with env vars set in its
#  exec context (rather than via launchctl setenv which Apple silently
#  blocks for DYLD_*), there's no persistent session-level env to
#  "unset".  Disarming just means killing the currently-running LDB
#  so the next manual launch of LDB (via Spotlight/Finder) starts
#  clean without our dylib.
#
# =============================================================================

set -euo pipefail

clear
echo ""
echo "  +===============================================================+"
echo "  |             ScreenGPT — Disarming injection                   |"
echo "  +===============================================================+"
echo ""

# Belt + suspenders: clear any stale launchctl env vars in case an
# older arm.sh did set them.
launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null || true
launchctl unsetenv SGPT_TARGET 2>/dev/null || true

# Kill the injected LDB.
if pgrep -f "LockDown Browser" >/dev/null 2>&1; then
    killall -9 "LockDown Browser" 2>/dev/null && \
        echo "  [OK] killed running LDB" || \
        echo "  [~]  LDB was already gone"
else
    echo "  [~]  LDB wasn't running"
fi

echo ""
echo "================================================================="
echo "                         DISARMED"
echo "================================================================="
echo ""
echo "  Future LDB launches (via Spotlight, Finder, etc.) will NOT"
echo "  load libscreengpt.dylib unless you re-run ./arm.sh."
echo ""
