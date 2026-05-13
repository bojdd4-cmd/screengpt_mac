#!/usr/bin/env bash
# =============================================================================
#  step2b_diagnose_exit.sh
#  ---------------------------------------------------------------------------
#  Step 2 proved DYLD_INSERT_LIBRARIES works (our constructor fired) but
#  LDB didn't call ANY of the SecCodeCheckValidity-family APIs we hooked.
#  So LDB's integrity check is using a different mechanism.
#
#  This step builds a MUCH more aggressive diagnostic dylib that hooks:
#
#     • exit, _Exit, abort      — captures the moment LDB decides to quit,
#                                  with a full stack trace of who called it.
#                                  This single signal tells us which
#                                  function in LDB is the integrity-failure
#                                  handler.
#
#     • All Sec* APIs           — every Apple Security framework call gets
#                                  logged with arguments + return values.
#                                  If LDB uses any of these in its check
#                                  path, we'll see it.
#
#     • dlsym                   — captures dynamic symbol lookups; will
#                                  catch "stealth" use of APIs LDB looks
#                                  up at runtime instead of importing.
#
#  After the launch, /tmp/integrity_bypass.log will tell us:
#
#     1. Did LDB call exit() vs just return from main?
#     2. What function called exit (top stack frame)?
#     3. What Sec* APIs were touched in the lead-up to exit?
#     4. What dynamic lookups happened?
#
#  Usage:
#      chmod +x step2b_diagnose_exit.sh
#      ./step2b_diagnose_exit.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYPASS_DIR="$SCRIPT_DIR/bypass"
mkdir -p "$BYPASS_DIR"

SRC="$BYPASS_DIR/integrity_bypass.c"
OUT="$BYPASS_DIR/integrity_bypass.dylib"
LOG="/tmp/integrity_bypass.log"

# ── Write the diagnostic dylib source ────────────────────────────────────
cat > "$SRC" <<'EOF'
//
//  integrity_bypass.c  (diagnostic build)
//  ----------------------------------------------------------------------
//  Wide net of hooks to learn WHAT LDB calls before it self-terminates.
//

#include <Security/Security.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

// ── Logging ────────────────────────────────────────────────────────────
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

__attribute__((format(printf, 1, 2)))
static void mlog(const char *fmt, ...) {
    pthread_mutex_lock(&log_lock);
    FILE *f = fopen("/tmp/integrity_bypass.log", "a");
    if (f) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        fprintf(f, "[%ld.%03ld] ", (long)ts.tv_sec, (long)(ts.tv_nsec / 1000000));
        va_list args;
        va_start(args, fmt);
        vfprintf(f, fmt, args);
        va_end(args);
        fprintf(f, "\n");
        fclose(f);
    }
    pthread_mutex_unlock(&log_lock);
}

static void log_backtrace(const char *header) {
    void *frames[64];
    int n = backtrace(frames, 64);
    mlog("%s — backtrace (%d frames):", header, n);
    char **symbols = backtrace_symbols(frames, n);
    if (symbols) {
        for (int i = 0; i < n; i++) {
            mlog("  [%2d] %s", i, symbols[i] ? symbols[i] : "(null)");
        }
        free(symbols);
    }
}

// ── DYLD_INTERPOSE macro ─────────────────────────────────────────────────
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

// ── exit / _Exit / abort hooks — these capture the moment of death ─────

__attribute__((noreturn))
void my_exit(int status) {
    mlog("=== exit(%d) intercepted ===", status);
    log_backtrace("exit called from");
    mlog("=== passing through to real exit ===");
    // Get the real exit function
    void (*real)(int) __attribute__((noreturn)) = dlsym(RTLD_NEXT, "exit");
    if (real) real(status);
    // Should never get here, but just in case
    _exit(status);
}

__attribute__((noreturn))
void my__Exit(int status) {
    mlog("=== _Exit(%d) intercepted ===", status);
    log_backtrace("_Exit called from");
    void (*real)(int) __attribute__((noreturn)) = dlsym(RTLD_NEXT, "_Exit");
    if (real) real(status);
    _exit(status);
}

__attribute__((noreturn))
void my_abort(void) {
    mlog("=== abort() intercepted ===");
    log_backtrace("abort called from");
    void (*real)(void) __attribute__((noreturn)) = dlsym(RTLD_NEXT, "abort");
    if (real) real();
    _exit(1);
}

DYLD_INTERPOSE(my_exit,  exit)
DYLD_INTERPOSE(my__Exit, _Exit)
DYLD_INTERPOSE(my_abort, abort)

// ── Sec* hooks — log every call, pass through to real, force success
//     for the validity checks.
// ───────────────────────────────────────────────────────────────────────

OSStatus my_SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags,
                                  SecRequirementRef requirement) {
    mlog("SecCodeCheckValidity(code=%p, flags=0x%x, req=%p) -> errSecSuccess (FORCED)",
         code, flags, requirement);
    return errSecSuccess;
}

OSStatus my_SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags,
                                            SecRequirementRef requirement,
                                            CFErrorRef *errors) {
    mlog("SecCodeCheckValidityWithErrors(code=%p, flags=0x%x) -> errSecSuccess (FORCED)",
         code, flags);
    if (errors) *errors = NULL;
    return errSecSuccess;
}

OSStatus my_SecStaticCodeCheckValidity(SecStaticCodeRef code, SecCSFlags flags,
                                        SecRequirementRef requirement) {
    mlog("SecStaticCodeCheckValidity(code=%p, flags=0x%x) -> errSecSuccess (FORCED)",
         code, flags);
    return errSecSuccess;
}

OSStatus my_SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self) {
    OSStatus (*real)(SecCSFlags, SecCodeRef*) = dlsym(RTLD_NEXT, "SecCodeCopySelf");
    OSStatus s = real ? real(flags, self) : -1;
    mlog("SecCodeCopySelf(flags=0x%x) -> %d, ref=%p", flags, (int)s,
         self ? *self : NULL);
    return s;
}

OSStatus my_SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags,
                                          CFDictionaryRef *information) {
    OSStatus (*real)(SecStaticCodeRef, SecCSFlags, CFDictionaryRef*) =
        dlsym(RTLD_NEXT, "SecCodeCopySigningInformation");
    OSStatus s = real ? real(code, flags, information) : -1;
    mlog("SecCodeCopySigningInformation(code=%p, flags=0x%x) -> %d",
         code, flags, (int)s);
    if (s == errSecSuccess && information && *information) {
        // Log key parts of the dict
        const void *teamID = CFDictionaryGetValue(*information,
                                CFSTR("teamid"));
        const void *ident = CFDictionaryGetValue(*information,
                                CFSTR("identifier"));
        if (teamID) {
            char buf[256] = "?";
            CFStringGetCString((CFStringRef)teamID, buf, sizeof(buf),
                               kCFStringEncodingUTF8);
            mlog("  teamID=%s", buf);
        }
        if (ident) {
            char buf[256] = "?";
            CFStringGetCString((CFStringRef)ident, buf, sizeof(buf),
                               kCFStringEncodingUTF8);
            mlog("  identifier=%s", buf);
        }
    }
    return s;
}

OSStatus my_SecRequirementCreateWithString(CFStringRef text, SecCSFlags flags,
                                            SecRequirementRef *requirement) {
    char buf[1024] = "?";
    if (text) {
        CFStringGetCString(text, buf, sizeof(buf), kCFStringEncodingUTF8);
    }
    mlog("SecRequirementCreateWithString(\"%s\", flags=0x%x)", buf, flags);
    OSStatus (*real)(CFStringRef, SecCSFlags, SecRequirementRef*) =
        dlsym(RTLD_NEXT, "SecRequirementCreateWithString");
    return real ? real(text, flags, requirement) : -1;
}

OSStatus my_SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags,
                                         SecStaticCodeRef *staticCode) {
    char buf[1024] = "?";
    if (path) {
        CFStringRef pathStr = CFURLGetString(path);
        if (pathStr) CFStringGetCString(pathStr, buf, sizeof(buf),
                                         kCFStringEncodingUTF8);
    }
    mlog("SecStaticCodeCreateWithPath(%s, flags=0x%x)", buf, flags);
    OSStatus (*real)(CFURLRef, SecCSFlags, SecStaticCodeRef*) =
        dlsym(RTLD_NEXT, "SecStaticCodeCreateWithPath");
    return real ? real(path, flags, staticCode) : -1;
}

DYLD_INTERPOSE(my_SecCodeCheckValidity,             SecCodeCheckValidity)
DYLD_INTERPOSE(my_SecCodeCheckValidityWithErrors,   SecCodeCheckValidityWithErrors)
DYLD_INTERPOSE(my_SecStaticCodeCheckValidity,       SecStaticCodeCheckValidity)
DYLD_INTERPOSE(my_SecCodeCopySelf,                  SecCodeCopySelf)
DYLD_INTERPOSE(my_SecCodeCopySigningInformation,    SecCodeCopySigningInformation)
DYLD_INTERPOSE(my_SecRequirementCreateWithString,   SecRequirementCreateWithString)
DYLD_INTERPOSE(my_SecStaticCodeCreateWithPath,      SecStaticCodeCreateWithPath)

// ── Constructor ──────────────────────────────────────────────────────────
__attribute__((constructor))
static void on_load(void) {
    // Truncate log on each launch.
    FILE *f = fopen("/tmp/integrity_bypass.log", "w");
    if (f) {
        fprintf(f, "=== dylib loaded into pid %d ===\n", getpid());
        fclose(f);
    }
}
EOF

echo "Wrote: $SRC"

# ── Compile ──────────────────────────────────────────────────────────────
echo ""
echo "Compiling (x86_64, with execinfo for backtrace)..."
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

# ── Print launch command ─────────────────────────────────────────────────
cat <<NOTE
═══════════════════════════════════════════════════════════════════════
DIAGNOSTIC DYLIB BUILT.  Now launch LDB with it:

    rm -f $LOG
    DYLD_INSERT_LIBRARIES="$OUT" \\
      "/Applications/LockDown Browser.app/Contents/MacOS/LockDown Browser"

When LDB exits (with or without the corruption dialog), examine the log:

    cat $LOG

The most important section is the exit/abort backtrace.  Look for the
"=== exit(N) intercepted ===" line followed by backtrace frames.  The
top few frames AFTER our hook should show:

  [0] ...integrity_bypass.dylib... my_exit
  [1] ...some LDB function...        <-- this is what called exit
  [2] ...another LDB function...     <-- and this is what called THAT
  ...

Paste the relevant slice of the log here and we'll identify the check.
═══════════════════════════════════════════════════════════════════════
NOTE
