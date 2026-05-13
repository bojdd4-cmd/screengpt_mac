#!/usr/bin/env bash
# =============================================================================
#  step2_integrity_bypass.sh
#  ---------------------------------------------------------------------------
#  LDB self-integrity-check bypass.
#
#  LDB calls standard Apple Security framework APIs to check its own
#  signature at startup:
#       SecCodeCheckValidity, SecCodeCheckValidityWithErrors,
#       SecStaticCodeCheckValidity
#
#  These are dynamically-linked imports.  DYLD_INTERPOSE lets us replace
#  them with our own implementations that always return errSecSuccess.
#  When LDB asks Apple "am I validly signed?" our dylib intercepts the
#  call and answers "yes, perfectly valid."
#
#  This script:
#     1. Writes integrity_bypass.c (the hook source)
#     2. Compiles it as an x86_64 dylib (LDB is thin x86_64 under Rosetta)
#     3. Ad-hoc signs the dylib
#     4. Prints the launch command for the user to try
#
#  Usage:
#      chmod +x step2_integrity_bypass.sh
#      ./step2_integrity_bypass.sh
#
#  Requires step 1c to have already re-signed LDB.  Re-running step1c is
#  safe (it restores from backup first).
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYPASS_DIR="$SCRIPT_DIR/bypass"
mkdir -p "$BYPASS_DIR"

SRC="$BYPASS_DIR/integrity_bypass.c"
OUT="$BYPASS_DIR/integrity_bypass.dylib"
LOG="/tmp/integrity_bypass.log"

# ── 1. Write the dylib source ─────────────────────────────────────────────
cat > "$SRC" <<'EOF'
//
//  integrity_bypass.c
//  ----------------------------------------------------------------------
//  DYLD_INTERPOSE hooks for Apple Security framework APIs that LDB uses
//  to check its own signature.  Loaded into LDB via DYLD_INSERT_LIBRARIES.
//
//  Coverage based on nm output of LDB's binary:
//
//     SecCodeCheckValidity              → always errSecSuccess
//     SecCodeCheckValidityWithErrors    → always errSecSuccess + nil errors
//     SecStaticCodeCheckValidity        → always errSecSuccess
//
//  If LDB also checks the signing info dict (team-id comparison), we'll
//  add a SecCodeCopySigningInformation hook in a follow-up.
//

#include <Security/Security.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

// ── Logging (so we can see when each hook fires) ────────────────────────
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

static void log_event(const char *fn, OSStatus returned) {
    pthread_mutex_lock(&log_lock);
    FILE *f = fopen("/tmp/integrity_bypass.log", "a");
    if (f) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        fprintf(f, "[%ld.%03ld] pid=%d  %-40s -> 0x%x (%d)\n",
                (long)ts.tv_sec, (long)(ts.tv_nsec / 1000000),
                getpid(), fn, returned, returned);
        fclose(f);
    }
    pthread_mutex_unlock(&log_lock);
}

// ── DYLD_INTERPOSE macro ────────────────────────────────────────────────
//
// Places (replacement, replacee) tuples into the special __DATA,__interpose
// section that dyld reads at load time.  For each tuple, dyld redirects
// callers of `replacee` to call `replacement` instead.  Works only on
// dynamically-linked imports — perfect for Security framework calls.
//
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

// ── Hooks ────────────────────────────────────────────────────────────────

OSStatus my_SecCodeCheckValidity(SecCodeRef code,
                                  SecCSFlags flags,
                                  SecRequirementRef requirement) {
    log_event("SecCodeCheckValidity", errSecSuccess);
    return errSecSuccess;
}

OSStatus my_SecCodeCheckValidityWithErrors(SecCodeRef code,
                                            SecCSFlags flags,
                                            SecRequirementRef requirement,
                                            CFErrorRef *errors) {
    log_event("SecCodeCheckValidityWithErrors", errSecSuccess);
    if (errors) *errors = NULL;
    return errSecSuccess;
}

OSStatus my_SecStaticCodeCheckValidity(SecStaticCodeRef code,
                                        SecCSFlags flags,
                                        SecRequirementRef requirement) {
    log_event("SecStaticCodeCheckValidity", errSecSuccess);
    return errSecSuccess;
}

// ── Constructor (fires before LDB's main()) ─────────────────────────────

__attribute__((constructor))
static void on_load(void) {
    // Truncate the log on a fresh launch so each test session is clean.
    FILE *f = fopen("/tmp/integrity_bypass.log", "w");
    if (f) {
        fprintf(f, "=== integrity_bypass dylib loaded into pid %d ===\n", getpid());
        fclose(f);
    }
}

// ── Interpose registrations ─────────────────────────────────────────────

DYLD_INTERPOSE(my_SecCodeCheckValidity,            SecCodeCheckValidity)
DYLD_INTERPOSE(my_SecCodeCheckValidityWithErrors,  SecCodeCheckValidityWithErrors)
DYLD_INTERPOSE(my_SecStaticCodeCheckValidity,      SecStaticCodeCheckValidity)
EOF

echo "Wrote: $SRC"

# ── 2. Compile (x86_64 to match LDB) ──────────────────────────────────────
echo ""
echo "Compiling..."
clang -arch x86_64 -dynamiclib \
      -framework Security \
      -framework CoreFoundation \
      -Wno-deprecated-declarations \
      -o "$OUT" "$SRC"

if [ ! -f "$OUT" ]; then
    echo "❌  Compile failed."
    exit 1
fi

# ── 3. Ad-hoc sign the dylib ─────────────────────────────────────────────
echo "Signing..."
codesign --force --sign - "$OUT"

echo ""
ls -la "$OUT"
file "$OUT"
echo ""

# ── 4. Print the launch command ──────────────────────────────────────────
cat <<NOTE
═══════════════════════════════════════════════════════════════════════
Dylib built and signed.  Now launch LDB with it injected:

    rm -f $LOG
    DYLD_INSERT_LIBRARIES="$OUT" \\
      "/Applications/LockDown Browser.app/Contents/MacOS/LockDown Browser"

After LDB exits (or doesn't), check the hook log:

    cat $LOG

What to look for:
  • "=== integrity_bypass dylib loaded ===" — confirms the dylib was
    actually loaded by dyld (the first big test).
  • "SecCodeCheckValidity -> 0x0" lines — confirms LDB called the hook
    and got back errSecSuccess.
  • If you see multiple hook lines and LDB stays running → BYPASS WORKED.
  • If the dylib loaded but LDB still exits → LDB has additional checks
    we need to hook (probably SecCodeCopySigningInformation).

If LDB launches and stays open, ship a celebratory beer.
═══════════════════════════════════════════════════════════════════════
NOTE
