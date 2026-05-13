#!/usr/bin/env bash
# =============================================================================
#  build_dylib.sh — build libscreengpt.dylib (Phase 1 minimal)
# =============================================================================
#
#  Compiles screengpt_dylib.m into a universal arm64+x86_64 dylib, ad-hoc
#  signs it, and copies it to /usr/local/lib/libscreengpt.dylib for the
#  arm.sh script to inject into LDB.
#
#  Requires:
#      • Xcode Command Line Tools (clang, codesign)
#      • SIP disabled
#      • AMFI disabled  (boot-arg amfi_get_out_of_my_way=1)
#
#  Usage:
#      ./build_dylib.sh
#
# =============================================================================

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

SOURCE=screengpt_dylib.m
OUT_LOCAL=libscreengpt.dylib            # built here in the source folder
INSTALL_PATH=/usr/local/lib/libscreengpt.dylib

echo "============================================="
echo "  ScreenGPT loader dylib build"
echo "============================================="
echo "  Source:   $here/$SOURCE"
echo "  Output:   $here/$OUT_LOCAL"
echo "  Deploy:   $INSTALL_PATH"
echo ""

# ── 1.  Compile universal arm64+x86_64 ─────────────────────────────────────
echo "[1/3] Compiling (universal arm64+x86_64)..."
clang -dynamiclib \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=11.0 \
    -framework Foundation \
    -framework Cocoa \
    -framework CoreGraphics \
    -fobjc-arc \
    -O2 \
    -Wall \
    -o "$OUT_LOCAL" \
    "$SOURCE"
echo "  OK: built $OUT_LOCAL"

# Quick lipo sanity check
ARCHS="$(lipo -archs "$OUT_LOCAL" 2>/dev/null || echo unknown)"
echo "  Architectures: $ARCHS"

# ── 2.  Ad-hoc sign ────────────────────────────────────────────────────────
# With AMFI disabled, ad-hoc-signed dylibs can be loaded into
# hardened-runtime processes via DYLD_INSERT_LIBRARIES.  No real cert
# needed for Phase 1.
echo ""
echo "[2/3] Ad-hoc signing..."
codesign --force --sign - "$OUT_LOCAL"
codesign --verify --verbose "$OUT_LOCAL" 2>&1 | sed 's/^/  /'

# ── 3.  Deploy to /usr/local/lib so arm.sh can find it ─────────────────────
echo ""
echo "[3/3] Deploying to $INSTALL_PATH (needs sudo)..."
sudo mkdir -p "$(dirname "$INSTALL_PATH")"
sudo cp -f "$OUT_LOCAL" "$INSTALL_PATH"
sudo chmod 0644 "$INSTALL_PATH"
sudo chown root:wheel "$INSTALL_PATH" 2>/dev/null || true
echo "  OK: installed at $INSTALL_PATH"

echo ""
echo "============================================="
echo "  Build complete."
echo "  Next: ./arm.sh   (sets env vars + kills LDB)"
echo "============================================="
