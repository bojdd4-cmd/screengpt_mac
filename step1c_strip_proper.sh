#!/usr/bin/env bash
# =============================================================================
#  step1c_strip_proper.sh
#  ---------------------------------------------------------------------------
#  Step 1b had a bug: `plutil -remove "com.apple.foo.bar"` treats the
#  dotted name as a path (com → apple → foo → bar) and silently fails to
#  remove flat keys that contain dots.  Only `keychain-access-groups`
#  (no dots) was actually removed.
#
#  This rewrite uses `PlistBuddy` which uses colons as path separators,
#  so dotted keys at the root level can be targeted directly with `:key`.
#
#  Strips every Apple-restricted entitlement amfid is rejecting.  After
#  this, LDB should launch (without proctoring capability — which we'll
#  deal with separately if exams break).
#
#  Usage:
#      chmod +x step1c_strip_proper.sh
#      ./step1c_strip_proper.sh
# =============================================================================

set -uo pipefail

LDB="/Applications/LockDown Browser.app"
BACKUP="$LDB.original"
PB="/usr/libexec/PlistBuddy"

# ── 1. Pre-flight ──────────────────────────────────────────────────────────
if [ ! -d "$BACKUP" ]; then
    echo "❌  No backup at $BACKUP — run step1_test_resign.sh first."
    exit 1
fi

if pgrep -fl "LockDown Browser" >/dev/null 2>&1; then
    echo "⚠️   LockDown Browser is running.  Quit it first."
    exit 1
fi

if [ ! -x "$PB" ]; then
    echo "❌  PlistBuddy not found at $PB"
    exit 1
fi

# ── 2. Restore from backup so we start clean ───────────────────────────────
echo "Restoring LDB from backup..."
sudo rm -rf "$LDB"
sudo cp -R "$BACKUP" "$LDB"
echo "  Done."
echo ""

# ── 3. Extract entitlements to a working plist ─────────────────────────────
TMP_ENT="$(mktemp -t ldb_ent).plist"
codesign -d --entitlements :- "$LDB" > "$TMP_ENT" 2>/dev/null

if [ ! -s "$TMP_ENT" ]; then
    echo "❌  Could not extract entitlements from $LDB."
    exit 1
fi

echo "── Original entitlements ──"
plutil -p "$TMP_ENT" | sed 's/^/  /'
echo ""

# ── 4. Strip restricted entitlements (PlistBuddy this time) ────────────────
# Per amfid log message:
#    "Requirements for restricted entitlements failed to validate, error -67688"
# These are the keys macOS gates with a "must be Apple-signed" requirement.
RESTRICTED_KEYS=(
    # Identity / Apple-signed-claim entitlements (the big ones)
    "com.apple.application-identifier"
    "com.apple.developer.team-identifier"
    "com.apple.developer.automatic-assessment-configuration"

    # Apple-event / mach-lookup whitelists (requires Apple co-sign)
    "com.apple.security.automation.apple-events"
    "com.apple.security.temporary-exception.mach-lookup.global-name"

    # Keychain group claim (requires TeamIdentifier)
    "keychain-access-groups"
)

echo "── Stripping restricted entitlements (via PlistBuddy) ──"
for key in "${RESTRICTED_KEYS[@]}"; do
    # PlistBuddy "Print :keyname" returns 0 if the key exists.
    if "$PB" -c "Print :$key" "$TMP_ENT" >/dev/null 2>&1; then
        "$PB" -c "Delete :$key" "$TMP_ENT" 2>&1 | sed 's/^/    /'
        # Verify it's gone
        if ! "$PB" -c "Print :$key" "$TMP_ENT" >/dev/null 2>&1; then
            echo "  ✂  removed: $key"
        else
            echo "  ⚠   couldn't remove: $key"
        fi
    else
        echo "  -  not present: $key"
    fi
done
echo ""

echo "── Cleaned entitlements (what we'll re-apply) ──"
plutil -p "$TMP_ENT" | sed 's/^/  /'
echo ""

# ── 5. Re-sign with cleaned entitlements ───────────────────────────────────
echo "── Ad-hoc re-signing with cleaned entitlements ──"
sudo codesign --force --deep --sign - --entitlements "$TMP_ENT" "$LDB" 2>&1 | sed 's/^/  /'
RESIGN_EC=$?
echo "  codesign exit code: $RESIGN_EC"

if [ $RESIGN_EC -ne 0 ]; then
    echo ""
    echo "❌  Re-sign FAILED."
    exit 1
fi

# ── 6. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "── Verifying ──"
codesign --verify --verbose "$LDB" 2>&1 | tail -3 | sed 's/^/  /'
VERIFY_EC=$?
echo "  verify exit code: $VERIFY_EC"

# ── 7. Show post-strip entitlements as actually applied ───────────────────
echo ""
echo "── Final entitlements as applied to LDB ──"
codesign -d --entitlements :- "$LDB" 2>/dev/null | plutil -p - | sed 's/^/  /'

# ── 8. Quarantine cleanup ─────────────────────────────────────────────────
sudo xattr -dr com.apple.quarantine "$LDB" 2>/dev/null && \
    echo "" && echo "Cleared com.apple.quarantine."

# ── 9. Summary + next step ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "STEP 1c RESULT"
echo "═══════════════════════════════════════════════════════════════════════"
if [ $RESIGN_EC -eq 0 ] && [ $VERIFY_EC -eq 0 ]; then
    echo "🟢  Re-sign with PROPERLY stripped entitlements succeeded."
    echo ""
    echo "Try launching:"
    echo ""
    echo "    open \"$LDB\""
    echo ""
    echo "Then check amfid log to confirm no rejection:"
    echo ""
    echo "    log show --last 1m --predicate 'process == \"amfid\"' --info | tail -30"
    echo ""
    echo "Possible outcomes:"
    echo "  • LDB opens to welcome screen → success.  Test exam start."
    echo "  • Still POSIX 162 + amfid still complaining → more keys to strip."
    echo "    Paste the new amfid output."
    echo "  • Different error (crash report, etc.) → paste it."
else
    echo "🔴  Something failed.  See output above."
fi
echo ""
echo "Restore original LDB anytime:"
echo "    sudo rm -rf \"$LDB\""
echo "    sudo cp -R \"$BACKUP\" \"$LDB\""
echo ""
