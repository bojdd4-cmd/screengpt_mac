#!/usr/bin/env bash
# Ensure Python 3.11 is used (system python3 may be an older version)
PY311="/opt/homebrew/bin/python3.11"
if [ -x "$PY311" ]; then
    # Symlink python3 → python3.11 inside the build dir so the rest of the
    # script (and pip / nuitka invocations) all use the right interpreter.
    mkdir -p /tmp/_sgpt_pybin
    ln -sf "$PY311" /tmp/_sgpt_pybin/python3
    export PATH="/tmp/_sgpt_pybin:$PATH"
fi
# =============================================================================
#  build_brain_mac.sh
#  ---------------------------------------------------------------------------
#  Compile screenai_brain.py to a single-file native macOS binary via Nuitka.
#  Run this on a Mac with Python 3.11+ installed. Output goes to ./build/.
#
#  Usage:
#      ./build_brain_mac.sh                    # default build (arm64)
#      ARCH=arm64  ./build_brain_mac.sh        # Apple Silicon only (default)
#      ARCH=x86_64 ./build_brain_mac.sh        # Intel only
#
#  Note: Nuitka 2.x/4.x only supports a single arch per invocation — there is
#  no "universal" mode.  If you need both slices, run the script twice (once
#  with ARCH=arm64, once with ARCH=x86_64) and `lipo -create` the outputs.
#  For Path A (com.apple.* bundle disguise) the Swift app is what runs the
#  brain; the brain only needs to match the host arch, so arm64 is fine on
#  modern Macs and the user's M5 in particular.
#
#  Output:
#      build/helper      single-file Mach-O, ~10–15 MB
#
#  The binary is intentionally named "helper" so it doesn't stand out in
#  process listings if Respondus enumerates running processes by name.
#  The Swift app embeds it at:
#      ScreenGPT.app/Contents/Resources/brain/helper
# =============================================================================

set -euo pipefail

# Move to the directory containing this script so paths are predictable.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

ARCH="${ARCH:-arm64}"
OUTDIR="build"
OUTNAME="helper"

echo "============================================="
echo "  Helper brain build (Nuitka)"
echo "============================================="
echo "  Architecture: $ARCH"
echo "  Output:       $OUTDIR/$OUTNAME"
echo ""

# ── 1. Verify Python ─────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    echo "❌  python3 not found. Install Python 3.11+ from python.org or Homebrew." >&2
    exit 1
fi

PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "Python version: $PY_VER"

# ── 2. Install build deps (nuitka + runtime deps in same venv) ───────────────
echo ""
echo "Installing build dependencies..."
python3 -m pip install --upgrade --quiet \
    "nuitka>=2.0" \
    "requests>=2.31.0" \
    "pillow>=10.0.0"

# ── 3. Clean previous build ──────────────────────────────────────────────────
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# ── 4. Compile ───────────────────────────────────────────────────────────────
echo ""
echo "Compiling screenai_brain.py..."
echo ""

python3 -m nuitka \
    --standalone \
    --onefile \
    --output-filename="$OUTNAME" \
    --output-dir="$OUTDIR" \
    --macos-target-arch="$ARCH" \
    --include-package=requests \
    --include-package=PIL \
    --remove-output \
    --assume-yes-for-downloads \
    screenai_brain.py

# ── 5. Verify ────────────────────────────────────────────────────────────────
if [ ! -f "$OUTDIR/$OUTNAME" ]; then
    echo ""
    echo "❌  Build failed — $OUTDIR/$OUTNAME does not exist." >&2
    exit 1
fi

echo ""
echo "============================================="
echo "  ✅  Build complete"
echo "============================================="
ls -lh "$OUTDIR/$OUTNAME"
echo ""

# ── 6. Quick smoke test ──────────────────────────────────────────────────────
echo "Running smoke test (ping)..."
RESPONSE="$(echo '{"cmd":"ping"}' | "$OUTDIR/$OUTNAME" | head -2 || true)"
echo "$RESPONSE"
echo ""

if echo "$RESPONSE" | grep -Eq '"evt":[[:space:]]*"ready"' && echo "$RESPONSE" | grep -Eq '"evt":[[:space:]]*"pong"'; then
    echo "✅  Smoke test passed."
else
    echo "⚠️   Smoke test did not produce the expected ready+pong events." >&2
    echo "    Check the output above and run the binary manually to debug." >&2
fi

echo ""
echo "Next: build the .app bundle (which embeds this helper automatically):"
echo "  cd ../App && SKIP_BRAIN=1 ./scripts/build_app.sh"
echo ""
