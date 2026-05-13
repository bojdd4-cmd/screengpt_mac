#!/usr/bin/env bash
# =============================================================================
#  step1_test_resign.sh
#  ---------------------------------------------------------------------------
#  Tests whether we can ad-hoc re-sign LockDown Browser on this Mac.
#  This is the foundation question for the new architecture: if Apple has
#  blocked re-signing of system apps on macOS Tahoe / Apple Silicon, the
#  whole dylib-injection approach is dead and we need a different plan.
#
#  What it does:
#     1. Locate LDB on disk
#     2. Print LDB's current signature + entitlements (so we know what
#        we're dealing with)
#     3. Back up LDB.app → LDB.app.original (so we can restore)
#     4. Extract entitlements into a temp plist
#     5. Run `codesign --force --deep --sign -` (ad-hoc re-sign)
#     6. Verify the new signature
#     7. Print a clear pass/fail summary
#
#  What it does NOT do:
#     • Modify LDB's binary (no insert_dylib yet — that's step 2)
#     • Add or remove entitlements (preserves Respondus's original ones)
#     • Launch LDB (you do that manually after the script finishes)
#
#  Requires:
#     • SIP disabled (csrutil status should say "disabled")
#     • macOS Reduced Security mode (set in Recovery → Startup Security
#       Utility) — optional for this step but needed for step 2
#     • sudo (to modify /Applications/LockDown Browser.app)
#
#  Usage:
#     chmod +x step1_test_resign.sh
#     ./step1_test_resign.sh
#
#  Output of interest:
#     • The "STEP 1 RESULT" block at the bottom
#     • If the result is OK → try to launch LDB manually
#     • If LDB launches and runs normally → step 1 fully passes
#     • If LDB refuses to launch → paste the error to us
#
#  Restoring the original LDB (if anything goes wrong):
#     sudo rm -rf "/Applications/LockDown Browser.app"
#     sudo mv "/Applications/LockDown Browser.app.original" \
#             "/Applications/LockDown Browser.app"
# =============================================================================

set -uo pipefail   # NOT -e — we want to capture failures, not abort on them

# ── 1. Locate LDB ───────────────────────────────────────────────────────────
LDB_CANDIDATES=(
    "/Applications/LockDown Browser.app"
    "/Applications/LockDown Browser OEM.app"
)

LDB=""
for path in "${LDB_CANDIDATES[@]}"; do
    if [ -d "$path" ]; then
        LDB="$path"
        break
    fi
done

if [ -z "$LDB" ]; then
    echo "❌  Could not find LockDown Browser.  Searched:"
    printf '    %s\n' "${LDB_CANDIDATES[@]}"
    exit 1
fi

LDB_BIN_DIR="$LDB/Contents/MacOS"
echo "Found LDB at:"
echo "  $LDB"
echo ""

# ── 2. Quick safety checks ──────────────────────────────────────────────────
if pgrep -fl "LockDown Browser" >/dev/null 2>&1; then
    echo "⚠️   LockDown Browser appears to be running.  Quit it before continuing."
    echo "    Running processes:"
    pgrep -fl "LockDown Browser" | sed 's/^/      /'
    exit 1
fi

echo "── System security state ──"
csrutil status 2>&1 | sed 's/^/  /'
echo ""

# Save BootArgs (no AMFI bypass expected on M5/Tahoe — informational only).
echo "  boot-args:        $(sudo nvram boot-args 2>/dev/null || echo '(none)')"
echo ""

# ── 3. Inspect current signature ────────────────────────────────────────────
echo "── LDB current signature (before re-sign) ──"
codesign -dv --verbose=4 "$LDB" 2>&1 | sed 's/^/  /' | head -30
echo ""

echo "── LDB current entitlements (before re-sign) ──"
codesign -d --entitlements :- "$LDB" 2>/dev/null \
    | head -60 | sed 's/^/  /' \
    || echo "  (could not extract entitlements)"
echo ""

# ── 4. Confirm with user ────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════"
echo "About to ad-hoc re-sign:"
echo "  $LDB"
echo ""
echo "This replaces the Respondus signature with an ad-hoc one (same"
echo "entitlements, just a different identity).  A backup will be saved at"
echo "  $LDB.original"
echo ""
echo "If anything goes wrong, restore with:"
echo "  sudo rm -rf \"$LDB\""
echo "  sudo mv \"$LDB.original\" \"$LDB\""
echo "═══════════════════════════════════════════════════════════════════════"
read -p "Continue? [y/N] " CONFIRM
if [ "${CONFIRM:-}" != "y" ] && [ "${CONFIRM:-}" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

# ── 5. Backup (idempotent — won't overwrite an existing backup) ─────────────
if [ -d "$LDB.original" ]; then
    echo ""
    echo "Backup already exists at $LDB.original — keeping it."
else
    echo ""
    echo "Creating backup at $LDB.original ..."
    sudo cp -R "$LDB" "$LDB.original"
    if [ ! -d "$LDB.original" ]; then
        echo "❌  Backup failed.  Aborting before any modification."
        exit 1
    fi
fi

# ── 6. Extract entitlements to preserve them ────────────────────────────────
TMP_ENTITLEMENTS="$(mktemp -t ldb_entitlements).plist"
echo ""
echo "Extracting entitlements to $TMP_ENTITLEMENTS ..."
codesign -d --entitlements :- "$LDB" > "$TMP_ENTITLEMENTS" 2>/dev/null
if [ -s "$TMP_ENTITLEMENTS" ]; then
    echo "  $(wc -l < "$TMP_ENTITLEMENTS") lines extracted."
else
    echo "  (LDB had no entitlements, or extraction failed — proceeding anyway)"
    rm -f "$TMP_ENTITLEMENTS"
    TMP_ENTITLEMENTS=""
fi

# ── 7. Ad-hoc re-sign ───────────────────────────────────────────────────────
echo ""
echo "── Ad-hoc re-signing ──"
if [ -n "$TMP_ENTITLEMENTS" ]; then
    sudo codesign --force --deep --sign - \
                  --entitlements "$TMP_ENTITLEMENTS" \
                  "$LDB" 2>&1 | sed 's/^/  /'
else
    sudo codesign --force --deep --sign - "$LDB" 2>&1 | sed 's/^/  /'
fi
RESIGN_EC=$?
echo "  codesign exit code: $RESIGN_EC"

# ── 8. Verify the new signature ─────────────────────────────────────────────
echo ""
echo "── Verifying new signature ──"
codesign --verify --verbose=4 "$LDB" 2>&1 | sed 's/^/  /'
VERIFY_EC=$?
echo "  verify exit code:   $VERIFY_EC"

# ── 9. Strict verification (full bundle hash check) ─────────────────────────
echo ""
echo "── Strict verification ──"
codesign --verify --strict --verbose=4 "$LDB" 2>&1 | sed 's/^/  /'
STRICT_EC=$?
echo "  strict exit code:   $STRICT_EC"

# ── 10. Gatekeeper assessment (informational) ──────────────────────────────
echo ""
echo "── Gatekeeper assessment (informational — ad-hoc may be rejected) ──"
spctl --assess --verbose "$LDB" 2>&1 | sed 's/^/  /'
SPCTL_EC=$?
echo "  spctl exit code:    $SPCTL_EC"

# ── 11. Show the new signature for comparison ──────────────────────────────
echo ""
echo "── LDB signature (after re-sign) ──"
codesign -dv --verbose=4 "$LDB" 2>&1 | sed 's/^/  /' | head -30

# ── 12. Final summary ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "STEP 1 RESULT"
echo "═══════════════════════════════════════════════════════════════════════"

emoji() { [ "$1" = 0 ] && echo "✅ OK" || echo "❌ FAILED ($1)"; }

echo "  codesign re-sign:       $(emoji $RESIGN_EC)"
echo "  signature verify:       $(emoji $VERIFY_EC)"
echo "  strict verify:          $(emoji $STRICT_EC)"
echo "  Gatekeeper assessment:  $(emoji $SPCTL_EC)  (rejection is fine for ad-hoc)"
echo ""

if [ $RESIGN_EC -eq 0 ] && [ $VERIFY_EC -eq 0 ]; then
    echo "🟢  Ad-hoc re-signing WORKS on this machine."
    echo ""
    echo "Next: try to LAUNCH LDB manually to confirm macOS accepts the"
    echo "re-signed bundle at runtime:"
    echo ""
    echo "    open \"$LDB\""
    echo ""
    echo "Expected outcomes:"
    echo "  • LDB opens normally → step 1 passes end-to-end, move to step 2"
    echo "  • macOS shows 'damaged / can't open' → may need 'xattr -dr"
    echo "    com.apple.quarantine \"$LDB\"' first"
    echo "  • LDB crashes immediately → entitlements may have been mangled"
    echo "  • Anything else → paste the error message to debug"
else
    echo "🔴  Ad-hoc re-signing FAILED on this machine."
    echo "    The dylib-injection architecture is blocked on this OS."
    echo "    Paste the codesign/verify output above so we can diagnose."
fi
echo ""
echo "To restore the original LDB at any time:"
echo "    sudo rm -rf \"$LDB\""
echo "    sudo mv \"$LDB.original\" \"$LDB\""
echo ""
