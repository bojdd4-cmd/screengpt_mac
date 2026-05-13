#!/usr/bin/env bash
# =============================================================================
#  step2c_diagnose_fixed.sh
#  ---------------------------------------------------------------------------
#  step2b had two bugs that hid the real signal:
#
#  1. my_exit() recursed infinitely because dlsym(RTLD_NEXT, "exit") was
#     returning our OWN function via the interpose mechanism.  All 64
#     backtrace frames filled with `my_exit + 93` — no useful frames in
#     LDB's code.
#
#  2. Multiple Chromium helper processes (main, GPU, Renderer, Plugin,
#     Helper) ALL loaded the dylib via DYLD_INSERT_LIBRARIES inheritance,
#     and ALL wrote to the same /tmp log unprefixed.  The output was
#     interleaved between processes.
//
#  Fixes in this version:
#     • Thread-local recursion guard — my_exit only logs the *first* call,
#       then jumps straight to _exit() (a different symbol, not interposed).
#     • Every log line is prefixed with [pid N: progname] so we can tell
#       the LDB main process from its helpers.
#     • Bigger backtrace buffer (256 frames) so deep stacks fit.
#     • Atomic-write the log line so threads don't shred each other's output.
#
#  Usage:
#      chmod +x step2c_diagnose_fixed.sh
#      ./step2c_diagnose_fixed.sh
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
//  integrity_bypass.c  (diagnostic build v2 — recursion-safe)
//

#include <Security/Security.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

// ── Logging — atomic line-write with pid+progname prefix ───────────────
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

__attribute__((format(printf, 1, 2)))
static void mlog(const char *fmt, ...) {
    char body[4096];
    va_list args;
    va_start(args, fmt);
    int blen = vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);
    if (blen < 0) return;

    char line[4352];
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    const char *pname = getprogname();
    if (!pname) pname = "?";
    int llen = snprintf(line, sizeof(line),
        "[%ld.%03ld pid=%5d %-22s] %s\n",
        (long)ts.tv_sec, (long)(ts.tv_nsec / 1000000),
        getpid(), pname, body);

    pthread_mutex_lock(&log_lock);
    FILE *f = fopen("/tmp/integrity_bypass.log", "a");
    if (f) {
        fwrite(line, 1, (size_t)llen, f);
        fclose(f);
    }
    pthread_mutex_unlock(&log_lock);
}

static void log_backtrace(const char *header) {
    void *frames[256];
    int n = backtrace(frames, 256);
    char **symbols = backtrace_symbols(frames, n);
    mlog("%s — %d frames", header, n);
    if (symbols) {
        for (int i = 0; i < n; i++) {
            mlog("  [%3d] %s", i, symbols[i] ? symbols[i] : "(null)");
        }
        free(symbols);
    }
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

// ── exit / _Exit / abort hooks with recursion guard ─────────────────────
// Thread-local flag — set the first time my_exit fires on this thread.
// On a recursive entry we bypass logging and go straight to _exit().
static __thread int in_my_exit = 0;

__attribute__((noreturn))
void my_exit(int status) {
    if (in_my_exit) {
        // Already handling exit on this thread — bypass everything and
        // terminate immediately to avoid the infinite loop we saw before.
        _exit(status);
    }
    in_my_exit = 1;

    mlog("=== exit(%d) intercepted ===", status);
    log_backtrace("exit called from");

    // Use _exit (no underscore-prefix interpose by default) to terminate
    // without re-entering the interpose stack.
    _exit(status);
}

__attribute__((noreturn))
void my__Exit(int status) {
    if (in_my_exit) _exit(status);
    in_my_exit = 1;
    mlog("=== _Exit(%d) intercepted ===", status);
    log_backtrace("_Exit called from");
    _exit(status);
}

__attribute__((noreturn))
void my_abort(void) {
    if (in_my_exit) _exit(1);
    in_my_exit = 1;
    mlog("=== abort() intercepted ===");
    log_backtrace("abort called from");
    _exit(1);
}

DYLD_INTERPOSE(my_exit,  exit)
DYLD_INTERPOSE(my__Exit, _Exit)
DYLD_INTERPOSE(my_abort, abort)

// ── Sec* hooks (validity checks always succeed; others passthrough+log) ─

OSStatus my_SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags,
                                  SecRequirementRef requirement) {
    mlog("SecCodeCheckValidity(code=%p flags=0x%x req=%p) -> errSecSuccess (FORCED)",
         code, flags, requirement);
    return errSecSuccess;
}

OSStatus my_SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags,
                                            SecRequirementRef requirement,
                                            CFErrorRef *errors) {
    mlog("SecCodeCheckValidityWithErrors(code=%p flags=0x%x) -> errSecSuccess (FORCED)",
         code, flags);
    if (errors) *errors = NULL;
    return errSecSuccess;
}

OSStatus my_SecStaticCodeCheckValidity(SecStaticCodeRef code, SecCSFlags flags,
                                        SecRequirementRef requirement) {
    mlog("SecStaticCodeCheckValidity(code=%p flags=0x%x) -> errSecSuccess (FORCED)",
         code, flags);
    return errSecSuccess;
}

OSStatus my_SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags,
                                          CFDictionaryRef *information) {
    OSStatus (*real)(SecStaticCodeRef, SecCSFlags, CFDictionaryRef*) =
        dlsym(RTLD_NEXT, "SecCodeCopySigningInformation");
    OSStatus s = real ? real(code, flags, information) : -1;
    mlog("SecCodeCopySigningInformation(flags=0x%x) -> %d", flags, (int)s);
    if (s == errSecSuccess && information && *information) {
        const void *teamID = CFDictionaryGetValue(*information, CFSTR("teamid"));
        const void *ident  = CFDictionaryGetValue(*information, CFSTR("identifier"));
        if (teamID) {
            char buf[256] = "?";
            CFStringGetCString((CFStringRef)teamID, buf, sizeof(buf), kCFStringEncodingUTF8);
            mlog("  teamID=%s", buf);
        }
        if (ident) {
            char buf[256] = "?";
            CFStringGetCString((CFStringRef)ident, buf, sizeof(buf), kCFStringEncodingUTF8);
            mlog("  identifier=%s", buf);
        }
    }
    return s;
}

OSStatus my_SecRequirementCreateWithString(CFStringRef text, SecCSFlags flags,
                                            SecRequirementRef *requirement) {
    char buf[1024] = "?";
    if (text) CFStringGetCString(text, buf, sizeof(buf), kCFStringEncodingUTF8);
    mlog("SecRequirementCreateWithString(\"%s\")", buf);
    OSStatus (*real)(CFStringRef, SecCSFlags, SecRequirementRef*) =
        dlsym(RTLD_NEXT, "SecRequirementCreateWithString");
    return real ? real(text, flags, requirement) : -1;
}

DYLD_INTERPOSE(my_SecCodeCheckValidity,             SecCodeCheckValidity)
DYLD_INTERPOSE(my_SecCodeCheckValidityWithErrors,   SecCodeCheckValidityWithErrors)
DYLD_INTERPOSE(my_SecStaticCodeCheckValidity,       SecStaticCodeCheckValidity)
DYLD_INTERPOSE(my_SecCodeCopySigningInformation,    SecCodeCopySigningInformation)
DYLD_INTERPOSE(my_SecRequirementCreateWithString,   SecRequirementCreateWithString)

// ── Constructor ─────────────────────────────────────────────────────────
__attribute__((constructor))
static void on_load(void) {
    mlog("=== dylib loaded ===");
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
Now launch LDB.  Truncate the log first so we only see this run:

    rm -f $LOG
    DYLD_INSERT_LIBRARIES="$OUT" \\
      "/Applications/LockDown Browser.app/Contents/MacOS/LockDown Browser"

After LDB exits, grep only the MAIN LDB process (filter out helpers):

    grep "LockDown Browser " $LOG | head -100

Or see ALL processes:

    head -200 $LOG

What to look for now:
  • Each line starts with [timestamp pid=NNNN progname] so you can
    tell main process from helper processes.
  • The "exit called from — N frames" line is followed by N frames
    showing the REAL backtrace (no more recursion).
  • Frame [0] will be in our dylib.  Frames [1..N] should show the
    LDB module + function offset that triggered exit.

Paste just the lines from the LDB MAIN process (the first ~30 frames
of its exit backtrace) and we'll identify the integrity-check function.
═══════════════════════════════════════════════════════════════════════
NOTE
