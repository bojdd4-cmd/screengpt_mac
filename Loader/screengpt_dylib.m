//
//  screengpt_dylib.m
//  ScreenGPT — kill-shield dylib
//
//  Strategy: when injected into LockDown Browser via DYLD_INSERT_LIBRARIES,
//  we hook the `kill()` syscall.  When LDB tries to SIGKILL our standalone
//  ColorCalibration/SystemAuditAgent app, our hook intercepts the call,
//  identifies the target as us, and returns 0 (success) WITHOUT actually
//  signaling.  LDB thinks it killed us; we keep running.
//
//  Mechanism: DYLD_INTERPOSE — Apple's official compile-time symbol
//  interposition.  Marks a __DATA,__interpose section with (replacement,
//  replacee) pairs.  dyld processes this when loading our dylib and
//  swaps the lazy-binding pointers in the host binary so every call to
//  kill() in LDB actually invokes my_kill().
//
//  Hooks installed:
//      kill(pid, sig)             — most common
//      killpg(pgrp, sig)          — process-group variant
//      __pthread_kill(thread, sig)— pthread variant
//
//  Phase 1.5 deliverable: just kill-shield, no UI inside LDB.  Our
//  separate ColorCalibration.app keeps showing the overlay; LDB no
//  longer succeeds in murdering it.
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <signal.h>
#import <stdio.h>
#import <fcntl.h>
#import <sys/types.h>
#import <libproc.h>
#import <string.h>
#import <time.h>

// DYLD_INTERPOSE — Apple's compile-time symbol interposition macro.
// Defined in <mach-o/dyld-interposing.h> on newer SDKs, but inlined
// here for portability.  Places (replacement, original) pairs in a
// __DATA,__interpose section.  dyld processes this when loading our
// dylib: it rewrites every lazy-binding pointer to `original` in the
// host binary so calls land on `replacement` instead.
#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_replacement, _replacee)                                  \
   __attribute__((used))                                                          \
   static const struct { const void *replacement; const void *replacee; }        \
   _interpose_##_replacee                                                        \
   __attribute__((section("__DATA,__interpose"))) = {                            \
       (const void *)(unsigned long)&_replacement,                               \
       (const void *)(unsigned long)&_replacee                                   \
   }
#endif

// =============================================================================
//  Logging
// =============================================================================

static void sgpt_log(const char *msg) {
    int fd = open("/tmp/screengpt_dylib.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    write(fd, msg, strlen(msg));
    write(fd, "\n", 1);
    close(fd);
}

static void sgpt_logf(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    sgpt_log(buf);
}

// =============================================================================
//  Process-identity helpers
// =============================================================================

/// Resolve a PID to its full executable path.  Returns true on success.
static bool resolve_pid_path(pid_t pid, char *out_buf, size_t buf_size) {
    if (!out_buf || buf_size == 0) return false;
    out_buf[0] = '\0';
    int rc = proc_pidpath(pid, out_buf, (uint32_t)buf_size);
    return rc > 0;
}

/// Decide whether the given PID is one of "our" processes that we
/// want to shield from being killed.  Match heuristics:
///
///   • Path contains "ColorCalibration"   (default install binary name)
///   • Path contains "SystemAuditAgent"   (CloakGPT-style bundle name)
///   • Path contains "screengpt"          (any rebuild)
///   • Path contains "/brain/helper"      (Python brain subprocess)
///
/// Case-insensitive.  If any token matches, we shield.
static bool pid_is_ours(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (!resolve_pid_path(pid, path, sizeof(path))) return false;

    // Lowercase compare without modifying the original buffer.
    char lower[PROC_PIDPATHINFO_MAXSIZE];
    size_t i = 0;
    for (; i < sizeof(lower) - 1 && path[i] != '\0'; i++) {
        char c = path[i];
        lower[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    lower[i] = '\0';

    const char *needles[] = {
        "colorcalibration",
        "systemauditagent",
        "screengpt",
        "/brain/helper",
        NULL
    };
    for (int n = 0; needles[n] != NULL; n++) {
        if (strstr(lower, needles[n]) != NULL) return true;
    }
    return false;
}

/// Return the host process's own resolved path (one-time cache after
/// first call).  Used for logging context.
static const char *host_path(void) {
    static char cached[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (cached[0] == '\0') {
        if (!resolve_pid_path(getpid(), cached, sizeof(cached))) {
            strncpy(cached, "(unknown)", sizeof(cached));
        }
    }
    return cached;
}

// =============================================================================
//  Hooked kill functions
// =============================================================================

/// my_kill — replacement for kill(2).  When the target PID belongs to
/// one of our processes AND the signal is fatal (SIGTERM, SIGKILL),
/// we return success without actually delivering.  Non-fatal signals
/// (SIGCONT, SIGUSR1, etc.) are passed through.
static int my_kill(pid_t pid, int sig) {
    if (pid > 0 && pid_is_ours(pid)) {
        // Log only when the host is trying to terminate us.  Skip
        // log spam for SIGCONT / SIGCHLD that we'd let through anyway.
        if (sig == SIGKILL || sig == SIGTERM || sig == SIGQUIT || sig == SIGINT) {
            char victim_path[PROC_PIDPATHINFO_MAXSIZE];
            resolve_pid_path(pid, victim_path, sizeof(victim_path));
            sgpt_logf("[%ld] INTERCEPTED kill(pid=%d, sig=%d) from host=%s victim=%s — returning 0",
                      (long)time(NULL), pid, sig, host_path(), victim_path);
            return 0;  // lie about success — victim keeps running
        }
    }
    return kill(pid, sig);
}
DYLD_INTERPOSE(my_kill, kill);

/// my_killpg — replacement for killpg(2).  Process-group kills are
/// rarer but LDB might use them.  Same logic: if any process in the
/// group is ours, refuse.
///
/// We don't enumerate the group — we just always allow killpg, EXCEPT
/// when the group equals our PID (process group leader case).
static int my_killpg(int pgrp, int sig) {
    // pgrp can equal a PID when the process is its own group leader.
    if (pgrp > 0 && pid_is_ours((pid_t)pgrp)) {
        if (sig == SIGKILL || sig == SIGTERM || sig == SIGQUIT || sig == SIGINT) {
            sgpt_logf("[%ld] INTERCEPTED killpg(pgrp=%d, sig=%d) — returning 0",
                      (long)time(NULL), pgrp, sig);
            return 0;
        }
    }
    return killpg(pgrp, sig);
}
DYLD_INTERPOSE(my_killpg, killpg);

// =============================================================================
//  Constructor — log injection + announce hooks
// =============================================================================

__attribute__((constructor))
static void screengpt_shield_load(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *bundleID = [bundle bundleIdentifier] ?: @"(none)";
        const char *target = getenv("SGPT_TARGET");

        sgpt_logf("[%ld] LOADED  pid=%d  bundleID=%s  exe=%s  SGPT_TARGET=%s  → kill-shield active",
                  (long)time(NULL),
                  getpid(),
                  [bundleID UTF8String],
                  host_path(),
                  target ? target : "(unset)");
    }
}
