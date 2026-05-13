#!/bin/bash
# =============================================================================
#  Uninstall.command — ColorCalibration / ScreenGPT
#  ---------------------------------------------------------------------------
#  Cleanly remove the deployed app + all the state Install.command set up:
#     • /Applications/Utilities/ColorCalibration.app  (the deployed bundle)
#     • TCC.db rows for com.apple.ColorCalibration    (system + user dbs)
#     • ScreenCaptureApprovals.plist entries          (replayd consent)
#     • Caches, preferences, saved state, install fingerprint marker
#
#  Safe to run even if nothing is installed — every step is best-effort.
#  Re-enables a clean reinstall by Install.command afterwards.
# =============================================================================

APP_NAME="ColorCalibration.app"
INSTALL_APP_PATH="/Applications/Utilities/$APP_NAME"
BUNDLE_ID="com.apple.ColorCalibration"

clear
echo ""
echo "  +===============================================================+"
echo "  |        ColorCalibration uninstaller                           |"
echo "  +===============================================================+"
echo ""

# Confirm
read -p "  Remove ColorCalibration and all its data? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "  Aborted."
    read -p "Press Enter to close..."
    exit 0
fi
echo ""

# Need sudo for the system paths and TCC.db
echo "  Requesting administrator access..."
VLT_ASKPASS=$(mktemp /tmp/.cc_askpass_XXXXXX)
cat > "$VLT_ASKPASS" << 'ASKPASS'
#!/bin/bash
osascript -e 'display dialog "ColorCalibration uninstaller needs administrator access." & return & return & "Enter your Mac login password:" with title "Administrator Access Required" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution' -e 'text returned of result' 2>/dev/null
ASKPASS
chmod +x "$VLT_ASKPASS"
export SUDO_ASKPASS="$VLT_ASKPASS"
if ! sudo -A -v 2>/dev/null; then
    echo "  ERROR: admin access denied. Cannot continue."
    rm -f "$VLT_ASKPASS"
    read -p "Press Enter to exit..."
    exit 1
fi
rm -f "$VLT_ASKPASS"
unset SUDO_ASKPASS

while true; do sudo -n true 2>/dev/null; sleep 50; done &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
echo "  OK - admin access granted"
echo ""

# ── 1.  Kill any running instance ───────────────────────────────────────────
echo "[1/6] Killing any running ColorCalibration instances..."
killall -9 ColorCalibration 2>/dev/null || true
killall -9 Calibration      2>/dev/null || true
pkill -9 -f "ColorCalibration" 2>/dev/null || true
pkill -9 -f "MacOS/Calibration" 2>/dev/null || true
sleep 1
echo "  OK"

# ── 2.  Remove the deployed bundle ──────────────────────────────────────────
echo "[2/6] Removing deployed bundle..."
if [ -d "$INSTALL_APP_PATH" ]; then
    sudo rm -rf "$INSTALL_APP_PATH" && echo "  OK - removed $INSTALL_APP_PATH"
else
    echo "  [~] $INSTALL_APP_PATH not present"
fi

# ── 3.  Remove TCC.db rows ──────────────────────────────────────────────────
echo "[3/6] Removing TCC.db rows..."
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

# System db
for SVC in kTCCServiceAccessibility kTCCServiceScreenCapture \
           kTCCServiceListenEvent   kTCCServiceMicrophone \
           kTCCServiceAppleEvents; do
    sudo sqlite3 "$TCC_DB" \
        "DELETE FROM access WHERE service='$SVC' AND client='$BUNDLE_ID';" 2>/dev/null \
        && echo "  [OK] removed system TCC: $SVC"
done

# User db
for SVC in kTCCServiceScreenCapture kTCCServiceMicrophone \
           kTCCServiceListenEvent   kTCCServiceAppleEvents; do
    sqlite3 "$USER_TCC_DB" \
        "DELETE FROM access WHERE service='$SVC' AND client='$BUNDLE_ID';" 2>/dev/null \
        && echo "  [OK] removed user TCC: $SVC"
done

# Restart tccd so changes take effect immediately
sudo killall tccd 2>/dev/null || true
echo "  OK - TCC rows removed"

# ── 4.  Remove ScreenCaptureApprovals.plist entries ─────────────────────────
echo "[4/6] Removing replayd consent..."
REPLAYD_PLIST="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
if [ -f "$REPLAYD_PLIST" ]; then
    DEPLOYED_EXE="$INSTALL_APP_PATH/Contents/MacOS/ColorCalibration"
    APP_FILE_URL="file://$INSTALL_APP_PATH/"
    for RKEY in "$BUNDLE_ID" "$APP_FILE_URL" "$DEPLOYED_EXE"; do
        defaults delete "$REPLAYD_PLIST" "$RKEY" 2>/dev/null || true
    done
    killall replayd 2>/dev/null || true
    echo "  OK - replayd consent removed"
else
    echo "  [~] $REPLAYD_PLIST not present"
fi

# ── 5.  Remove caches, prefs, saved state ───────────────────────────────────
echo "[5/6] Removing caches / preferences / saved state..."

rm -rf "$HOME/Library/Application Support/ColorCalibration"   2>/dev/null || true
rm -rf "$HOME/Library/Application Support/Color Calibration"  2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.apple.ColorCalibration"      2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.apple.ColorCalibration"*     2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.colorlab"*                   2>/dev/null || true
rm -rf "$HOME/Library/HTTPStorages/com.apple.ColorCalibration"* 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/com.apple.ColorCalibration.savedState" 2>/dev/null || true
rm -rf "$HOME/Library/WebKit/com.apple.ColorCalibration"      2>/dev/null || true
rm -rf "$HOME/Library/Containers/com.apple.ColorCalibration"  2>/dev/null || true
rm -rf "$HOME/Library/Logs/Color Calibration"                 2>/dev/null || true
rm -rf "$HOME/Library/Logs/ColorCalibration"                  2>/dev/null || true

defaults delete com.apple.ColorCalibration 2>/dev/null || true
defaults delete com.colorlab.calibration   2>/dev/null || true
killall cfprefsd 2>/dev/null || true

# Install fingerprint marker
rm -rf "$HOME/Library/Application Support/com.colorlab.installer" 2>/dev/null || true

echo "  OK - caches/prefs/state cleared"

# ── 6.  Refresh Launch Services ─────────────────────────────────────────────
echo "[6/6] Refreshing Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -kill -r -domain local -domain user 2>/dev/null &
echo "  OK - Launch Services rebuilding in background"

echo ""
echo "================================================================="
echo "                 UNINSTALL COMPLETE                              "
echo "================================================================="
echo ""
echo "  ColorCalibration is fully removed."
echo "  SIP and AMFI state are untouched — re-enable them yourself if"
echo "  you want to restore default macOS security (Recovery Mode →"
echo "  csrutil enable, then  sudo nvram -d boot-args  then reboot)."
echo ""
read -p "Press Enter to close..."
