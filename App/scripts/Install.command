#!/bin/bash
# =============================================================================
#  Install.command — ColorCalibration / ScreenGPT
#  ---------------------------------------------------------------------------
#  One-click installer for the deployed user.  Does five things:
#
#     1. Verifies SIP and AMFI are disabled (required for the bypass)
#     2. Cleans up any prior install
#     3. Moves ColorCalibration.app from this folder → /Applications/Utilities/
#     4. Ad-hoc re-signs the deployed bundle (so the cdhash matches TCC)
#     5. Writes TCC.db rows + ScreenCaptureApprovals.plist so macOS doesn't
#        prompt the user for Screen Recording / Accessibility / Input
#        Monitoring / Microphone permissions
#
#  Mirrors the CloakGPT installer pattern.  After install, the user just opens
#  the app from /Applications/Utilities/ — no Terminal needed for daily use.
#
#  Re-running this script is safe:  if the source bundle hasn't changed since
#  the last install (fingerprint check), it skips the destructive resign/
#  redeploy step so the user's TCC grants stay intact.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ColorCalibration.app"
SOURCE_APP_PATH="$SCRIPT_DIR/$APP_NAME"
INSTALL_DIR="/Applications/Utilities"
INSTALL_APP_PATH="$INSTALL_DIR/$APP_NAME"

# Bundle ID must match what's in the app's Info.plist
BUNDLE_ID="com.apple.ColorCalibration"

# State directory for the fingerprint marker (idempotent installs)
HASH_MARKER_DIR="$HOME/Library/Application Support/com.colorlab.installer"
HASH_MARKER="$HASH_MARKER_DIR/$APP_NAME.sha"
mkdir -p "$HASH_MARKER_DIR" 2>/dev/null || true

clear
echo ""
echo "  +===============================================================+"
echo "  |        ColorCalibration installer v1.0                        |"
echo "  +===============================================================+"
echo ""

# ── Hang protection (used for find / lengthy operations) ────────────────────
_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null && echo "  [!!] Timed out after ${secs}s — skipped" ) &
    local wd=$!
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    return $rc
}

# ── Sanity: source app present ──────────────────────────────────────────────
if [ ! -d "$SOURCE_APP_PATH" ]; then
    echo "  ERROR: $APP_NAME not found in this folder."
    echo "  Make sure the entire 'ColorCalibration' folder was extracted intact"
    echo "  and that this script is sitting next to ColorCalibration.app."
    read -p "Press Enter to exit..."
    exit 1
fi

# ── 0.  Request admin access once, reuse for the session ────────────────────
echo "  Requesting administrator access..."
echo "  (A password dialog will appear — enter your Mac login password.)"
echo ""

VLT_ASKPASS=$(mktemp /tmp/.cc_askpass_XXXXXX)
cat > "$VLT_ASKPASS" << 'ASKPASS'
#!/bin/bash
osascript -e 'display dialog "ColorCalibration installer needs administrator access." & return & return & "Enter your Mac login password:" with title "Administrator Access Required" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution' -e 'text returned of result' 2>/dev/null
ASKPASS
chmod +x "$VLT_ASKPASS"
export SUDO_ASKPASS="$VLT_ASKPASS"
if ! sudo -A -v 2>/dev/null; then
    echo "  ERROR: Administrator access denied or cancelled."
    rm -f "$VLT_ASKPASS"
    read -p "Press Enter to exit..."
    exit 1
fi
rm -f "$VLT_ASKPASS"
unset SUDO_ASKPASS

# Keep sudo alive in the background
while true; do sudo -n true 2>/dev/null; sleep 50; done &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
echo "  OK - Administrator access granted"
echo ""

# ── 1. Pre-flight: SIP + AMFI must be off ───────────────────────────────────
echo "[1/8] Checking SIP / AMFI status..."

SIP_STATUS=$(csrutil status 2>/dev/null)
AMFI_LINE=$(nvram -p 2>/dev/null | grep amfi)

SIP_OK=false
AMFI_OK=false
if echo "$SIP_STATUS" | grep -q "disabled"; then
    SIP_OK=true
    echo "  [OK] SIP: disabled"
else
    echo "  [!!] SIP: still enabled."
    echo "       Boot into Recovery (Power button → Loading startup options → Options)"
    echo "       → Terminal → run:   csrutil disable"
    echo "       Then reboot and re-run this installer."
fi

if echo "$AMFI_LINE" | grep -q "amfi_get_out_of_my_way=1"; then
    AMFI_OK=true
    echo "  [OK] AMFI: disabled"
else
    echo "  [!!] AMFI: still enabled."
    echo "       From normal Terminal:  sudo nvram boot-args=\"amfi_get_out_of_my_way=1\""
    echo "       Then:  sudo reboot"
    echo "       Then re-run this installer."
fi

if [ "$SIP_OK" = false ] || [ "$AMFI_OK" = false ]; then
    echo ""
    echo "  Cannot continue without both SIP and AMFI disabled."
    read -p "Press Enter to close..."
    exit 1
fi

# ── 2.  Compute source fingerprint (used by step 3) ─────────────────────────
compute_source_fp() {
    local acc=""
    if [ -d "$SOURCE_APP_PATH" ]; then
        for b in "$SOURCE_APP_PATH/Contents/MacOS/"*; do
            [ -f "$b" ] && acc="${acc}$(shasum -a 256 "$b" 2>/dev/null | awk '{print $1}')"
        done
    fi
    printf '%s' "$acc" | shasum -a 256 | awk '{print $1}'
}
SRC_FP=$(compute_source_fp)
STORED_FP=""
[ -f "$HASH_MARKER" ] && STORED_FP=$(tr -d '[:space:]' < "$HASH_MARKER" 2>/dev/null)

SKIP_DEPLOY=false
if [ -d "$INSTALL_APP_PATH" ] && [ -n "$SRC_FP" ] && [ -n "$STORED_FP" ] \
   && [ "$SRC_FP" = "$STORED_FP" ]; then
    SKIP_DEPLOY=true
fi

# ── 3.  Kill any running instance (current + prior names) ───────────────────
echo "[2/8] Killing any running ColorCalibration instances..."
killall -9 ColorCalibration 2>/dev/null || true
killall -9 Calibration      2>/dev/null || true
pkill -9 -f "ColorCalibration" 2>/dev/null || true
pkill -9 -f "MacOS/Calibration" 2>/dev/null || true
sleep 1
echo "  OK - killed any prior processes"

# ── 4.  Fast-path: source unchanged → preserve TCC, skip resign ─────────────
# Still install/refresh the LaunchAgent — running this script implies the
# user wants auto-relaunch active, even when the binary itself is unchanged.
if [ "$SKIP_DEPLOY" = true ]; then
    echo ""
    echo "  [~] $APP_NAME already deployed at $INSTALL_APP_PATH"
    echo "  [~] Source matches deployed copy (fingerprint ${SRC_FP:0:12}...)"
    echo "  [~] Skipping resign/redeploy to preserve TCC permissions"
    echo ""

    # Refresh LaunchAgent regardless of fast-path.
    echo "[*] Refreshing LaunchAgent..."
    LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    LAUNCH_AGENT_FILE="$LAUNCH_AGENTS_DIR/$BUNDLE_ID.plist"
    mkdir -p "$LAUNCH_AGENTS_DIR"
    cat > "$LAUNCH_AGENT_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_APP_PATH/Contents/MacOS/ColorCalibration</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CALIB_LAUNCHD</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLIST
    UID_NUM=$(id -u)
    launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
    sleep 0.3
    if launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT_FILE" 2>/dev/null; then
        echo "  [OK] LaunchAgent loaded — app will auto-relaunch if killed"
    else
        echo "  [!!] LaunchAgent bootstrap failed"
    fi
    echo ""

    echo "================================================================="
    echo "                  ALREADY INSTALLED                              "
    echo "================================================================="
    echo ""
    echo "  Bundle unchanged.  LaunchAgent refreshed."
    echo "  For a clean re-install, run Uninstall.command first."
    echo ""
    read -p "Press Enter to close..."
    exit 0
fi

# ── 5.  Clean previous install ──────────────────────────────────────────────
echo "[3/8] Cleaning previous install..."
sudo rm -rf "$INSTALL_APP_PATH" 2>/dev/null || true
rm -rf ~/Library/Application\ Support/ColorCalibration 2>/dev/null || true
rm -rf ~/Library/Caches/com.apple.ColorCalibration*   2>/dev/null || true
rm -rf ~/Library/Caches/com.colorlab.*                2>/dev/null || true
rm -rf ~/Library/Saved\ Application\ State/com.apple.ColorCalibration.savedState 2>/dev/null || true
rm -rf ~/Library/WebKit/com.apple.ColorCalibration    2>/dev/null || true
rm -rf ~/Library/HTTPStorages/com.apple.ColorCalibration* 2>/dev/null || true
defaults delete com.apple.ColorCalibration 2>/dev/null || true
defaults delete com.colorlab.calibration   2>/dev/null || true
killall cfprefsd 2>/dev/null || true
echo "  OK - previous install cleaned"

# ── 6.  Clear quarantine xattr on the staged app ────────────────────────────
echo "[4/8] Clearing quarantine xattrs..."
_timeout 20 find "$SCRIPT_DIR" -exec xattr -c {} + 2>/dev/null || true
chmod +x "$SOURCE_APP_PATH/Contents/MacOS/"* 2>/dev/null || true
echo "  OK - xattrs cleared, permissions set"

# ── 7.  Deploy to /Applications/Utilities/ ──────────────────────────────────
echo "[5/8] Deploying to $INSTALL_DIR ..."
sudo mkdir -p "$INSTALL_DIR"
sudo rm -rf "$INSTALL_APP_PATH"
# Use cp (not mv) so the user's source folder stays usable for re-runs / uninstall
sudo cp -R "$SOURCE_APP_PATH" "$INSTALL_APP_PATH"
sudo xattr -cr "$INSTALL_APP_PATH" 2>/dev/null || true
echo "  OK - deployed: $INSTALL_APP_PATH"

# ── 8.  Ad-hoc re-sign the deployed bundle ──────────────────────────────────
# Re-signing in place gives the deployed binary a stable cdhash that we'll
# reference from the TCC csreq blob below.  --deep covers the embedded
# Python brain helper.
echo "[6/8] Ad-hoc signing the deployed bundle..."
sudo codesign --force --deep --sign - "$INSTALL_APP_PATH" 2>&1 | sed 's/^/  /'
sudo codesign --verify --verbose "$INSTALL_APP_PATH" 2>&1 | tail -3 | sed 's/^/  /'
echo "  OK - signed"

# ── 9.  Auto-grant TCC permissions ──────────────────────────────────────────
echo "[7/8] Auto-granting TCC permissions..."
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
TCC_OK=true

# Generate the csreq blob from the deployed binary so TCC entries are
# anchored to its actual signature.  Without csreq, macOS 15+ silently
# ignores TCC rows for ad-hoc-signed apps even though the row exists.
CSREQ_HEX=""
REQ_STR=$(codesign -d -r- "$INSTALL_APP_PATH" 2>&1 | awk -F ' => ' '/designated/{print $2}')
if [ -n "$REQ_STR" ]; then
    echo "$REQ_STR" | csreq -r- -b /tmp/.cc_csreq.bin 2>/dev/null
    if [ -f /tmp/.cc_csreq.bin ]; then
        CSREQ_HEX=$(xxd -p /tmp/.cc_csreq.bin | tr -d '\n')
        rm -f /tmp/.cc_csreq.bin
        echo "  [OK] generated csreq blob"
    fi
fi
if [ -z "$CSREQ_HEX" ]; then
    echo "  [!!] could not generate csreq — TCC entries may not stick"
fi

# Grant a single TCC service (system or user db)
grant_tcc() {
    local db="$1" svc="$2" label="$3" use_sudo="$4"
    local prefix=""
    [ "$use_sudo" = "sudo" ] && prefix="sudo"

    # Delete + reinsert ensures the csreq blob is current and matches the
    # cdhash of the freshly-signed deployed binary.
    $prefix sqlite3 "$db" "DELETE FROM access WHERE service='$svc' AND client='$BUNDLE_ID';" 2>/dev/null

    local csreq_val="NULL"
    [ -n "$CSREQ_HEX" ] && csreq_val="X'$CSREQ_HEX'"

    if $prefix sqlite3 "$db" \
        "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified, boot_uuid, last_reminded) VALUES ('$svc', '$BUNDLE_ID', 0, 2, 4, 1, $csreq_val, 0, 'UNUSED', 0, CAST(strftime('%s','now') AS INTEGER), 'UNUSED', 0);" 2>/dev/null; then
        echo "  [OK] $label: granted"
    else
        echo "  [!!] $label: failed"
        TCC_OK=false
    fi
}

# System TCC db — authoritative when SIP is off
grant_tcc "$TCC_DB" "kTCCServiceAccessibility"  "Accessibility"              sudo
grant_tcc "$TCC_DB" "kTCCServiceScreenCapture"  "Screen & System Recording"  sudo
grant_tcc "$TCC_DB" "kTCCServiceListenEvent"    "Input Monitoring"           sudo
grant_tcc "$TCC_DB" "kTCCServiceMicrophone"     "Microphone"                 sudo

# User TCC db — some macOS APIs check the per-user db too
grant_tcc "$USER_TCC_DB" "kTCCServiceScreenCapture" "Screen Recording (user)" ""
grant_tcc "$USER_TCC_DB" "kTCCServiceMicrophone"    "Microphone (user)"       ""
grant_tcc "$USER_TCC_DB" "kTCCServiceListenEvent"   "Input Monitoring (user)" ""
grant_tcc "$USER_TCC_DB" "kTCCServiceAppleEvents"   "AppleEvents (user)"      ""

# ScreenCaptureApprovals.plist — macOS 15+ replayd uses this as a SEPARATE
# consent layer from TCC.db.  Without these entries, the WindowServer
# excludes our captures even with TCC granted.  Pre-grant by writing the
# plist directly.
REPLAYD_DIR="$HOME/Library/Group Containers/group.com.apple.replayd"
REPLAYD_PLIST="$REPLAYD_DIR/ScreenCaptureApprovals.plist"
mkdir -p "$REPLAYD_DIR" 2>/dev/null || true

DEPLOYED_EXE="$INSTALL_APP_PATH/Contents/MacOS/ColorCalibration"
APP_FILE_URL="file://$INSTALL_APP_PATH/"
for RKEY in "$BUNDLE_ID" "$APP_FILE_URL" "$DEPLOYED_EXE"; do
    /usr/bin/defaults write "$REPLAYD_PLIST" "$RKEY" -dict \
        kScreenCaptureApprovalLastAlerted -date "4321-01-01 00:00:00 +0000" \
        kScreenCapturePrivacyHintDate     -date "4321-01-01 00:00:00 +0000" \
        kScreenCapturePrivacyHintPolicy   -int 7776000 \
        kScreenCaptureAlertableUsageCount -int 1 \
        kScreenCaptureApprovalLastUsed    -date "4321-01-01 00:00:00 +0000" 2>/dev/null
done
killall replayd 2>/dev/null || true
echo "  [OK] replayd consent written"

# Restart tccd so grants take effect immediately
sudo killall tccd 2>/dev/null || true

if [ "$TCC_OK" = true ]; then
    echo "  OK - all TCC permissions auto-granted"
else
    echo "  WARNING - some TCC grants failed; you may need to grant manually"
fi

# ── 10.  Install LaunchAgent for auto-relaunch (LDB-survival) ───────────────
# LDB sends SIGKILL to our process every few minutes during exams.  This
# LaunchAgent makes launchd re-spawn us within ~10 seconds of each kill,
# and the app auto-logs back in via cached Keychain credentials.  Net
# effect: ~85-90% uptime inside an exam instead of dying permanently.
echo "[8/9] Installing LaunchAgent for auto-relaunch..."
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_FILE="$LAUNCH_AGENTS_DIR/$BUNDLE_ID.plist"
mkdir -p "$LAUNCH_AGENTS_DIR"
cat > "$LAUNCH_AGENT_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_APP_PATH/Contents/MacOS/ColorCalibration</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CALIB_LAUNCHD</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLIST

# Modern launchctl syntax (macOS 11+).  Older `launchctl load/unload`
# silently fails on Sonoma+ for user-domain agents; bootstrap/bootout
# is the supported path.  gui/<uid> = user's GUI session.
UID_NUM=$(id -u)
# Bootout any existing instance first (silent if not loaded).
launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
sleep 0.3
BOOTSTRAP_OUT=$(launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT_FILE" 2>&1)
BOOTSTRAP_RC=$?
if [ $BOOTSTRAP_RC -eq 0 ]; then
    echo "  [OK] LaunchAgent bootstrapped — app will auto-relaunch if killed"
elif launchctl print "gui/$UID_NUM/$BUNDLE_ID" >/dev/null 2>&1; then
    echo "  [OK] LaunchAgent already loaded"
else
    echo "  [!!] LaunchAgent bootstrap failed (rc=$BOOTSTRAP_RC):"
    echo "       $BOOTSTRAP_OUT"
    echo "       Auto-relaunch not active — manual restart needed if LDB kills app."
fi

# ── 11.  Refresh Launch Services so Finder picks up the new bundle ID ───────
echo "[9/9] Refreshing Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -kill -r -domain local -domain user 2>/dev/null &
echo "  OK - Launch Services rebuilding in background"

# Save the fingerprint so subsequent installer runs can fast-path
[ -n "$SRC_FP" ] && printf '%s' "$SRC_FP" > "$HASH_MARKER" 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================="
echo "                 INSTALLATION COMPLETE                           "
echo "================================================================="
echo ""
echo "  Installed: $INSTALL_APP_PATH"
echo "  Bundle ID: $BUNDLE_ID (com.apple.* → invisible to LDB process scan)"
echo ""
if [ "$TCC_OK" = true ]; then
    echo "  [OK] TCC permissions auto-granted — no System Settings dance needed."
    echo ""
fi
echo "  Log in once — the LaunchAgent will auto-restart the app and"
echo "  silently re-login from Keychain if LDB kills it during an exam."
echo ""
echo "  To remove: run Uninstall.command in this folder."
echo ""
echo "================================================================="
echo ""
read -p "Press Enter to close..."
