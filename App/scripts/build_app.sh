#!/usr/bin/env bash
# =============================================================================
#  build_app.sh
#  ---------------------------------------------------------------------------
#  Build the full .app bundle + a distribution folder ready for users.
#
#  Outputs:
#     build/ColorCalibration.app          — the assembled app bundle
#     build/dist/ColorCalibration/        — the shareable folder containing:
#         ColorCalibration.app
#         Install.command
#         Uninstall.command
#
#  The user downloads/copies the `ColorCalibration` folder to their Desktop,
#  double-clicks Install.command, and the installer moves the app to
#  /Applications/Utilities/, ad-hoc re-signs it, and pre-grants TCC.
#
#  Bypass technique:
#     We disguise the app as an Apple system component by using a
#     `com.apple.ColorCalibration` bundle ID.  Combined with SIP off + AMFI
#     off + ad-hoc signing, LockDown Browser's process-kill scan whitelists
#     anything matching `com.apple.*` so our app survives the exam.
#
#  Usage:
#     ./scripts/build_app.sh
#     OUTPUT=./dist ./scripts/build_app.sh                # custom output dir
#     SKIP_BRAIN=1 ./scripts/build_app.sh                 # reuse brain binary
#     BUNDLE_ID=com.apple.AnotherName ./scripts/build_app.sh
# =============================================================================

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$here"

OUTPUT="${OUTPUT:-build}"
APP="${OUTPUT}/ColorCalibration.app"
DIST_DIR="${OUTPUT}/dist/ColorCalibration"
BRAIN_DIR="$here/../Brain"

# Generic Mach-O name so we don't stand out in `ps` / proc_listpids.
EXEC_NAME="ColorCalibration"
BRAIN_NAME="helper"

# Architectures.  Default is arm64-only because that's all `swift build` can do
# with Command Line Tools alone — `--arch arm64 --arch x86_64` requires the
# full Xcode.app (xcbuild lives inside it).  Set UNIVERSAL=1 if you have
# Xcode.app installed and want an arm64+x86_64 fat binary.
#
# Note: an arm64-only overlay coexists fine with x86_64 Rosetta-LDB — they're
# two unrelated processes; the OS handles arch differences invisibly.
UNIVERSAL="${UNIVERSAL:-0}"
if [ "$UNIVERSAL" = "1" ]; then
    SWIFT_ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
    SWIFT_ARCH_FLAGS=(--arch arm64)
fi

# ── The com.apple.* bundle ID trick ─────────────────────────────────────────
# This is THE bypass.  LockDown Browser's process-kill scan whitelists any
# process whose CFBundleIdentifier starts with `com.apple.` (because killing
# real Apple system processes would crash the host).  We claim a plausible-
# looking but non-existent Apple bundle ID.  AMFI off (set by the user via
# `nvram boot-args="amfi_get_out_of_my_way=1"`) is required so macOS accepts
# the unsigned com.apple.* claim at launch.
BUNDLE_ID="${BUNDLE_ID:-com.apple.ColorCalibration}"

SHORT_VERSION="${SHORT_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DISPLAY_NAME="${DISPLAY_NAME:-Color Calibration}"

echo "============================================="
echo "  Color Calibration .app build"
echo "============================================="
echo "  Bundle ID:     $BUNDLE_ID"
echo "  Display name:  $DISPLAY_NAME"
echo "  Exec name:     $EXEC_NAME"
echo "  Version:       $SHORT_VERSION ($BUILD_NUMBER)"
echo "  App output:    $APP"
echo "  Dist folder:   $DIST_DIR"
echo ""

# ── 1.  Build the brain ─────────────────────────────────────────────────────
if [ "${SKIP_BRAIN:-0}" = "1" ]; then
    echo "[1/6] Skipping brain build (SKIP_BRAIN=1)"
else
    echo "[1/6] Building Python brain..."
    (cd "$BRAIN_DIR" && chmod +x build_brain_mac.sh && ./build_brain_mac.sh)
fi

if [ ! -x "$BRAIN_DIR/build/$BRAIN_NAME" ]; then
    echo "❌  Brain binary not found at $BRAIN_DIR/build/$BRAIN_NAME" >&2
    exit 1
fi

# ── 2.  Build the Swift executable (universal: arm64 + x86_64) ──────────────
echo ""
if [ "$UNIVERSAL" = "1" ]; then
    echo "[2/6] Building Swift executable (release, universal arm64+x86_64)..."
else
    echo "[2/6] Building Swift executable (release, arm64-only)..."
    echo "        (set UNIVERSAL=1 to build a universal binary — requires full Xcode.app)"
fi
swift build -c release "${SWIFT_ARCH_FLAGS[@]}"

SWIFT_EXEC="$(swift build -c release "${SWIFT_ARCH_FLAGS[@]}" --show-bin-path)/Calibration"
if [ ! -x "$SWIFT_EXEC" ]; then
    echo "❌  Swift executable not found at $SWIFT_EXEC" >&2
    exit 1
fi

# Print architectures actually present in the binary
ARCH_LIST="$(lipo -archs "$SWIFT_EXEC" 2>/dev/null || echo unknown)"
echo "  Architectures: $ARCH_LIST"
if [ "$UNIVERSAL" = "1" ] && ! echo "$ARCH_LIST" | grep -q "x86_64"; then
    echo "  ⚠️   UNIVERSAL=1 was set but the x86_64 slice is missing."
    echo "      Either Xcode.app isn't installed or xcbuild failed silently."
fi

# ── 3.  Assemble the .app bundle ────────────────────────────────────────────
echo ""
echo "[3/6] Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/brain"

cp "$SWIFT_EXEC"                  "$APP/Contents/MacOS/$EXEC_NAME"
cp "$BRAIN_DIR/build/$BRAIN_NAME" "$APP/Contents/Resources/brain/$BRAIN_NAME"

chmod +x "$APP/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP/Contents/Resources/brain/$BRAIN_NAME"

# ── 4.  Write Info.plist ────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- LSUIElement=true makes the app a "background-only" / agent app:
         no Dock icon, no menu bar, doesn't appear in Cmd+Tab.  Mirrors
         CloakGPT's behaviour — the app stays visible during LDB exams
         without showing in any system UI that LDB might scan. -->
    <key>LSUIElement</key>
    <true/>
    <!-- TCC usage descriptions.  Apple shows these strings if it ever
         prompts the user (it won't, since Install.command writes the
         consent rows directly into TCC.db). -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>$DISPLAY_NAME captures the screen so it can analyse on-screen content.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>$DISPLAY_NAME captures audio for analysis.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>$DISPLAY_NAME uses Apple Events for system integration.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>$DISPLAY_NAME uses Accessibility APIs for screen analysis.</string>
</dict>
</plist>
EOF

# Generate PkgInfo so Finder treats the bundle as a real app.
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# ── 5.  Ad-hoc sign the bundle ──────────────────────────────────────────────
echo ""
echo "[4/6] Ad-hoc signing the bundle..."
# Clear any extended attrs the build chain may have left (quarantine etc).
xattr -cr "$APP" 2>/dev/null || true
# `--deep` covers the Python brain helper inside Contents/Resources/brain/
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/  /'
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/  /'

# ── 6.  Build the distribution folder ───────────────────────────────────────
echo ""
echo "[5/6] Building distribution folder at $DIST_DIR ..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
# Copy the assembled app
cp -R "$APP" "$DIST_DIR/"
# Copy Install.command and Uninstall.command from the source tree
INSTALL_SRC="$here/scripts/Install.command"
UNINSTALL_SRC="$here/scripts/Uninstall.command"
for f in "$INSTALL_SRC" "$UNINSTALL_SRC"; do
    if [ ! -f "$f" ]; then
        echo "  ⚠️   missing: $f"
    else
        cp "$f" "$DIST_DIR/"
        chmod +x "$DIST_DIR/$(basename "$f")"
    fi
done

echo ""
echo "[6/6] Done."
echo ""
du -sh "$APP"
du -sh "$DIST_DIR"
echo ""
echo "What to ship to users:"
echo "  $DIST_DIR/"
echo ""
echo "Test locally (developer convenience):"
echo "  open \"$APP\""
echo ""
echo "User flow:"
echo "  1. Download / copy the 'ColorCalibration' folder to Desktop"
echo "  2. Double-click Install.command"
echo "  3. App installs to /Applications/Utilities/ColorCalibration.app"
echo ""
