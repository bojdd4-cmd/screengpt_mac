#!/usr/bin/env bash
# =============================================================================
#  step2d_forge_signing.sh
#  ---------------------------------------------------------------------------
#  Crash forensics from step 2c revealed:
#
#     • LDB calls SecCodeCopySigningInformation in
#       -[LDBAppDelegate applicationDidFinishCefInitialization]+734
#     • The wrapping function has a SHA-256-hex obfuscated name:
#       _26016b40d7d26475...0fe7a70f at offset 0xCC3F0 in LDB
#     • Our previous hook recursed 13,734 levels because
#       dlsym(RTLD_NEXT, "X") returns our interposed X on macOS
#     • The crash was OUR bug, not LDB's anti-tampering
#
#  The real check LDB does is: read teamid + identifier from the signing
#  info dict, compare against compiled-in constants:
#       teamid     = "8CA6NAN723"
#       identifier = "com.Respondus.LockDownBrowser"
#
#  Our re-signed LDB has teamid="" so the check fails and LDB exits.
#
#  This script's dylib forges the dictionary with the expected values.
#  No dlsym, no recursion — we just synthesize the right return value.
#
#  Usage:
#      chmod +x step2d_forge_signing.sh
#      ./step2d_forge_signing.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYPASS_DIR="$SCRIPT_DIR/bypass"
mkdir -p "$BYPASS_DIR"

SRC="$BYPASS_DIR/integrity_bypass.c"
OUT="$BYPASS_DIR/integrity_bypass.dylib"
LOG="/tmp/integrity_bypass.log"

cat > "$SRC" <<'EOF'
//
//  integrity_bypass.c — v3, signing-info forging build
//
//  Strategy: don't call the real Sec functions at all (avoids the
//  recursive dlsym(RTLD_NEXT) trap).  Just synthesize the return values
//  LDB's integrity check is looking for.
//

#include <Security/Security.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

// ── Logging ───────────────────────────────────────────────────────────────
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

__attribute__((format(printf, 1, 2)))
static void mlog(const char *fmt, ...) {
    char body[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);

    pthread_mutex_lock(&log_lock);
    FILE *f = fopen("/tmp/integrity_bypass.log", "a");
    if (f) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        fprintf(f, "[%ld.%03ld pid=%5d] %s\n",
                (long)ts.tv_sec, (long)(ts.tv_nsec / 1000000),
                getpid(), body);
        fclose(f);
    }
    pthread_mutex_unlock(&log_lock);
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

// ── Forge a signing-info dictionary LDB will accept ───────────────────────
//
// Keys come from <Security/SecCode.h>:
//   kSecCodeInfoIdentifier      = "identifier"
//   kSecCodeInfoTeamIdentifier  = "teamid"
//   kSecCodeInfoFlags           = "flags"
//   kSecCodeInfoStatus          = "status"
//   kSecCodeInfoFormat          = "format"
//   kSecCodeInfoCdHash          = "cdhash"
//
// LDB's check almost certainly compares teamid + identifier against
// hard-coded constants.  We populate those exactly; the rest is filler
// so the dict isn't suspiciously empty.

static CFDictionaryRef forge_signing_info(void) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!dict) return NULL;

    // The two values LDB compares ──────────
    CFDictionarySetValue(dict, CFSTR("identifier"),
                          CFSTR("com.Respondus.LockDownBrowser"));
    CFDictionarySetValue(dict, CFSTR("teamid"),
                          CFSTR("8CA6NAN723"));

    // Filler — these are the values a real Respondus-signed LDB returns ──
    // status: CS_VALID | CS_RUNTIME (hardened runtime + valid signature)
    int32_t status_val = 0x10001;
    CFNumberRef status = CFNumberCreate(NULL, kCFNumberSInt32Type, &status_val);
    CFDictionarySetValue(dict, CFSTR("status"), status);
    CFRelease(status);

    // flags: CS_VALID
    int32_t flags_val = 0x10000;
    CFNumberRef flags = CFNumberCreate(NULL, kCFNumberSInt32Type, &flags_val);
    CFDictionarySetValue(dict, CFSTR("flags"), flags);
    CFRelease(flags);

    // format: app bundle string
    CFDictionarySetValue(dict, CFSTR("format"),
                          CFSTR("app bundle with Mach-O thin (x86_64)"));

    return dict;
}

// ── Hooks ─────────────────────────────────────────────────────────────────

OSStatus my_SecCodeCopySigningInformation(SecStaticCodeRef code,
                                          SecCSFlags flags,
                                          CFDictionaryRef *information) {
    mlog("SecCodeCopySigningInformation(flags=0x%x) FORGED -> "
         "teamid=8CA6NAN723 identifier=com.Respondus.LockDownBrowser",
         flags);
    if (information) {
        *information = forge_signing_info();
    }
    return errSecSuccess;
}

// The validity-check family — keep these so any auxiliary check passes too.
OSStatus my_SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags,
                                  SecRequirementRef requirement) {
    mlog("SecCodeCheckValidity FORCED -> errSecSuccess");
    return errSecSuccess;
}

OSStatus my_SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags,
                                            SecRequirementRef requirement,
                                            CFErrorRef *errors) {
    mlog("SecCodeCheckValidityWithErrors FORCED -> errSecSuccess");
    if (errors) *errors = NULL;
    return errSecSuccess;
}

OSStatus my_SecStaticCodeCheckValidity(SecStaticCodeRef code, SecCSFlags flags,
                                        SecRequirementRef requirement) {
    mlog("SecStaticCodeCheckValidity FORCED -> errSecSuccess");
    return errSecSuccess;
}

DYLD_INTERPOSE(my_SecCodeCopySigningInformation,    SecCodeCopySigningInformation)
DYLD_INTERPOSE(my_SecCodeCheckValidity,             SecCodeCheckValidity)
DYLD_INTERPOSE(my_SecCodeCheckValidityWithErrors,   SecCodeCheckValidityWithErrors)
DYLD_INTERPOSE(my_SecStaticCodeCheckValidity,       SecStaticCodeCheckValidity)

// NOTE: We deliberately do NOT hook SecCodeCopySelf,
// SecStaticCodeCreateWithPath, or SecRequirementCreateWithString.
// Those return handles LDB will pass back into the check API — let them
// run normally.  Our hooks intercept at the comparison step, which is
// SecCodeCopySigningInformation.

__attribute__((constructor))
static void on_load(void) {
    // Fresh log per run
    FILE *f = fopen("/tmp/integrity_bypass.log", "w");
    if (f) {
        fprintf(f, "=== forge-signing dylib loaded into pid %d ===\n", getpid());
        fclose(f);
    }
}
EOF

echo "Wrote: $SRC"

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

codesign --force --sign - "$OUT"
echo ""
ls -la "$OUT"
echo ""

cat <<NOTE
═══════════════════════════════════════════════════════════════════════
BUILT.  Launch LDB with the new dylib:

    rm -f $LOG
    DYLD_INSERT_LIBRARIES="$OUT" \\
      "/Applications/LockDown Browser.app/Contents/MacOS/LockDown Browser"

Then:

    cat $LOG | grep -v "Helper"

Expected behavior:
  🟢  LDB opens normally to its welcome screen — bypass worked.
  🟡  LDB opens briefly then crashes/exits differently — there's a
      second integrity layer we'll need to find.
  🔴  Same crash as before — please paste the new log and we'll
      iterate.
═══════════════════════════════════════════════════════════════════════
NOTE
