#!/usr/bin/env bash
# =============================================================================
#  step1b_resign_clean.sh
#  ---------------------------------------------------------------------------
#  Step 1a (step1_test_resign.sh) succeeded at the re-sign step itself,
#  but LDB refused to launch afterward with POSIX 162 / "Launchd job spawn
#  failed".  Diagnosis: AMFI rejected the bundle because the ad-hoc
#  signature is claiming Apple-restricted entitlements (the proctoring
#  entitlement etc.) that require Apple's signing process to back them.
#
#  This script:
#     1. Restores LDB from the .original backup
#     2. Extracts entitlements
#     3. STRIPS the restricted ones (proctoring, app-identifier,
#        team-identifier, keychain-groups, temporary-exceptions)
#     4. Re-signs ad-hoc with the cleaned entitlement set
#     5. Verifies + suggests next-step launch
#
#  Trade-off: LDB without the proctoring entitlement may not be able to
#  perform the full assessment-agent dance.  We need to test whether it
#  can still launch + serve an exam *for our injection purposes*.  If
#  Respondus's school-side flow refuses to start an exam on a re-signed
#  LDB, we'll need a different approach (covered in the followup).
#
#  Usage:
#      chmod +x step1b_resign_clean.sh
#      ./step1b_resign_clean.sh
# =============================================================================

set -uo pipefail

LDB="/Applications/LockDown Browser.app"
BACKUP="$LDB.original"

# ── 1. Pre-flight ──────────────────────────────────────────────────────────
if [ ! -d "$BACKUP" ]; then
    echo "❌  No backup at $BACKUP — run step1_test_resign.sh first."
    exit 1
fi

if pgrep -fl "LockDown Browser" >/dev/null 2>&1; then
    echo "⚠️   LockDown Browser is running.  Quit it first."
    exit 1
fi

# ── 2. Restore from backup so we start clean ───────────────────────────────
echo "Restoring LDB from backup..."
sudo rm -rf "$LDB"
sudo cp -R "$BACKUP" "$LDB"
echo "  Done."
echo ""

# ── 3. Extract entitlements ────────────────────────────────────────────────
TMP_ENT="$(mktemp -t ldb_ent).plist"
codesign -d --entitlements :- "$LDB" > "$TMP_ENT" 2>/dev/null

if [ ! -s "$TMP_ENT" ]; then
    echo "❌  Could not extract entitlements from $LDB."
    exit 1
fi

echo "── Original entitlements (from Respondus signature) ──"
plutil -p "$TMP_ENT" | sed 's/^/  /'
echo ""

# ── 4. Strip restricted entitlements ───────────────────────────────────────
# These keys require Apple's signing process to authorize.  An ad-hoc
# signature can't back them, so AMFI rejects the bundle at launch.
RESTRICTED_KEYS=(
    "com.apple.developer.automatic-assessment-configuration"
    "com.apple.application-identifier"
    "com.apple.developer.team-identifier"
    "keychain-access-groups"
    "com.apple.security.temporary-exception.mach-lookup.global-name"
    "com.apple.security.temporary-exception.mach-lookup.global-name.array"
)

echo "── Stripping restricted entitlements ──"
for key in "${RESTRICTED_KEYS[@]}"; do
    if plutil -extract "$key" raw "$TMP_ENT" >/dev/null 2>&1; then
        plutil -remove "$key" "$TMP_ENT" 2>/dev/null
        echo "  ✂  removed: $key"
    fi
done
echo ""

echo "── Cleaned entitlements (to be re-applied) ──"
plutil -p "$TMP_ENT" | sed 's/^/  /'
echo ""

# ── 5. Re-sign with cleaned entitlements ───────────────────────────────────
echo "── Ad-hoc re-signing with cleaned entitlements ──"
sudo codesign --force --deep --sign - --entitlements "$TMP_ENT" "$LDB" 2>&1 | sed 's/^/  /'
RESIGN_EC=$?
echo "  codesign exit code: $RESIGN_EC"

if [ $RESIGN_EC -ne 0 ]; then
    echo ""
    echo "❌  Re-sign FAILED.  See codesign output above."
    exit 1
fi

# ── 6. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "── Verifying ──"
codesign --verify --verbose=4 "$LDB" 2>&1 | tail -5 | sed 's/^/  /'
VERIFY_EC=$?
echo "  verify exit code: $VERIFY_EC"

# ── 7. Show post-resign signature ─────────────────────────────────────────
echo ""
echo "── LDB signature after clean re-sign ──"
codesign -dv --verbose=2 "$LDB" 2>&1 | sed 's/^/  /' | head -15
echo ""

# ── 8. Try launch via spawn (gives better error info than open) ────────────
echo "── Pre-launch sanity (faster failure modes) ──"
xattr -dr com.apple.quarantine "$LDB" 2>/dev/null && echo "  cleared com.apple.quarantine" || true

# ── 9. Final summary ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "STEP 1b RESULT"
echo "═══════════════════════════════════════════════════════════════════════"
if [ $RESIGN_EC -eq 0 ] && [ $VERIFY_EC -eq 0 ]; then
    echo "🟢  Re-sign with stripped entitlements succeeded."
    echo ""
    echo "Now try to launch:"
    echo ""
    echo "    open \"$LDB\""
    echo ""
    echo "Possible outcomes:"
    echo ""
    echo "  • LDB opens and you reach the welcome screen"
    echo "      → LAUNCH ISSUE FIXED.  Now test if exams still work."
    echo "        Try to start a practice exam.  If it works → step 1"
    echo "        fully passes.  If it complains about the assessment"
    echo "        agent → we need a different path (covered next)."
    echo ""
    echo "  • Still POSIX 162 / Launchd spawn failed"
    echo "      → Run this to see the AMFI rejection reason:"
    echo ""
    echo "        log show --last 2m --predicate 'process == \"amfid\"' --info | tail -50"
    echo ""
    echo "        Paste the output — there's another entitlement we need"
    echo "        to strip."
    echo ""
    echo "  • Different error"
    echo "      → Paste the full error and any Console log lines."
else
    echo "🔴  Re-sign with stripped entitlements failed.  See output above."
fi
echo ""
echo "Restore original LDB anytime:"
echo "    sudo rm -rf \"$LDB\""
echo "    sudo cp -R \"$BACKUP\" \"$LDB\""
echo ""
