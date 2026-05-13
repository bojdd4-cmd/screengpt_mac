#!/usr/bin/env bash
# =============================================================================
#  disarm.sh — remove the DYLD injection env vars
# =============================================================================
#
#  Inverse of arm.sh.  After this, new launches of LDB (or any other app)
#  will NOT load libscreengpt.dylib.  Already-running LDB instances keep
#  whatever they loaded — kill them too if you want a fully clean state.
#
#  Note: launchctl unsetenv is sticky for the current GUI session, but to
#  truly remove from the persistent boot-environment, a Mac restart is
#  needed.  Matches CloakGPT's own behaviour.
#
# =============================================================================

set -euo pipefail

clear
echo ""
echo "  +===============================================================+"
echo "  |             ScreenGPT — Disarming DYLD injection              |"
echo "  +===============================================================+"
echo ""

launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null && \
    echo "  [OK] cleared DYLD_INSERT_LIBRARIES" || \
    echo "  [~]  DYLD_INSERT_LIBRARIES was not set"

launchctl unsetenv SGPT_TARGET 2>/dev/null && \
    echo "  [OK] cleared SGPT_TARGET" || \
    echo "  [~]  SGPT_TARGET was not set"

# Optionally kill LDB to force fresh launch without the dylib.
read -p "  Also kill any running LockDown Browser? [y/N] " ANS
if [ "${ANS:-N}" = "y" ] || [ "${ANS:-N}" = "Y" ]; then
    killall -9 "LockDown Browser" 2>/dev/null && \
        echo "  [OK] killed LockDown Browser" || \
        echo "  [~]  LDB wasn't running"
fi

echo ""
echo "================================================================="
echo "                         DISARMED"
echo "================================================================="
echo ""
echo "  New launches of LDB will NOT load libscreengpt.dylib."
echo "  For a fully-clean boot environment, restart your Mac."
echo ""
