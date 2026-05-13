//
//  screengpt_dylib.m
//  ScreenGPT — invisibility dylib
//
//  Strategy (Phase 1.6): when injected into LockDown Browser via
//  DYLD_INSERT_LIBRARIES, hook the macOS APIs LDB uses to enumerate
//  windows and running applications.  Filter OUR app out of those
//  results so LDB never sees us — no "another foreground application
//  detected" warning, no exam termination, no kill.
//
//  Hooks installed:
//      CGWindowListCopyWindowInfo / CGWindowListCreate
//          → strip windows whose owner name matches our app
//      NSWorkspace.runningApplications (method swizzle)
//          → filter out NSRunningApplications whose bundleID matches us
//      NSWorkspace.frontmostApplication (method swizzle)
//          → if it would return us, lie and return LDB itself
//      kill(2) / killpg(2)
//          → kept from Phase 1.5 as belt-and-suspenders
//
//  This is the actual CloakGPT pattern as inferred from their behaviour:
//  the standalone app stays running outside LDB, and the injected dylib
//  hides it from LDB's enumeration so LDB has no idea we exist.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <signal.h>
#import <stdio.h>
#import <fcntl.h>
#import <sys/types.h>
#import <libproc.h>
#import <string.h>
#import <time.h>

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
//  Match heuristics — what counts as "us"
// =============================================================================

/// Case-insensitive substring match against a set of tokens that
/// identify our app and helpers.  Used by both the C-level kill hooks
/// (via path) and the Cocoa-level swizzles (via bundle ID / name).
static bool string_is_ours(const char *s) {
    if (!s || !*s) return false;
    // Lowercase compare without modifying caller's buffer.
    char lower[1024];
    size_t i = 0;
    for (; i < sizeof(lower) - 1 && s[i] != '\0'; i++) {
        char c = s[i];
        lower[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    lower[i] = '\0';

    const char *needles[] = {
        "colorcalibration",
        "systemauditagent",
        "screengpt",
        "/brain/helper",
        NULL,
    };
    for (int n = 0; needles[n]; n++) {
        if (strstr(lower, needles[n])) return true;
    }
    return false;
}

static bool pid_is_ours(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return false;
    return string_is_ours(path);
}

static bool nsstring_is_ours(NSString *s) {
    if (!s) return false;
    const char *cs = [s UTF8String];
    return string_is_ours(cs);
}

// =============================================================================
//  Hook: kill / killpg  (Phase 1.5 — kept as belt-and-suspenders)
// =============================================================================

static int my_kill(pid_t pid, int sig) {
    if (pid > 0 && pid_is_ours(pid) &&
        (sig == SIGKILL || sig == SIGTERM || sig == SIGQUIT || sig == SIGINT)) {
        sgpt_logf("[%ld] INTERCEPTED kill(pid=%d, sig=%d) — returning 0",
                  (long)time(NULL), pid, sig);
        return 0;
    }
    return kill(pid, sig);
}
DYLD_INTERPOSE(my_kill, kill);

static int my_killpg(int pgrp, int sig) {
    if (pgrp > 0 && pid_is_ours((pid_t)pgrp) &&
        (sig == SIGKILL || sig == SIGTERM || sig == SIGQUIT || sig == SIGINT)) {
        sgpt_logf("[%ld] INTERCEPTED killpg(pgrp=%d, sig=%d) — returning 0",
                  (long)time(NULL), pgrp, sig);
        return 0;
    }
    return killpg(pgrp, sig);
}
DYLD_INTERPOSE(my_killpg, killpg);

// =============================================================================
//  Hook: CGWindowListCopyWindowInfo  (THE BIG ONE for foreground detection)
// =============================================================================
//
//  CGWindowListCopyWindowInfo returns a CFArray of CFDictionaries, one
//  per on-screen window.  Each dict has kCGWindowOwnerName,
//  kCGWindowOwnerPID, kCGWindowName, etc.  LDB almost certainly calls
//  this to detect "other apps with windows on screen" → triggers the
//  warning.  Our hook strips entries whose owner matches us.
// =============================================================================

static CFArrayRef my_CGWindowListCopyWindowInfo(CGWindowListOption option,
                                                 CGWindowID relativeToWindow) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(option, relativeToWindow);
    if (!raw) return NULL;

    CFIndex count = CFArrayGetCount(raw);
    CFMutableArrayRef filtered = CFArrayCreateMutable(kCFAllocatorDefault,
                                                      count,
                                                      &kCFTypeArrayCallBacks);
    int hidden = 0;
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef win = (CFDictionaryRef)CFArrayGetValueAtIndex(raw, i);
        BOOL drop = NO;

        // Check the window's owning process info.
        CFStringRef ownerName = (CFStringRef)CFDictionaryGetValue(win, kCGWindowOwnerName);
        if (ownerName) {
            char ownerBuf[256] = {0};
            CFStringGetCString(ownerName, ownerBuf, sizeof(ownerBuf), kCFStringEncodingUTF8);
            if (string_is_ours(ownerBuf)) drop = YES;
        }

        // Also check by PID → executable path (catches cases where
        // owner name is generic like "helper").
        if (!drop) {
            CFNumberRef ownerPIDRef = (CFNumberRef)CFDictionaryGetValue(win, kCGWindowOwnerPID);
            if (ownerPIDRef) {
                int pid = 0;
                CFNumberGetValue(ownerPIDRef, kCFNumberIntType, &pid);
                if (pid > 0 && pid_is_ours((pid_t)pid)) drop = YES;
            }
        }

        if (drop) {
            hidden++;
        } else {
            CFArrayAppendValue(filtered, win);
        }
    }
    if (hidden > 0) {
        sgpt_logf("[%ld] HID %d window(s) from CGWindowListCopyWindowInfo (returned %ld of %ld)",
                  (long)time(NULL), hidden, count - hidden, count);
    }
    CFRelease(raw);
    return filtered;
}
DYLD_INTERPOSE(my_CGWindowListCopyWindowInfo, CGWindowListCopyWindowInfo);

// =============================================================================
//  Hook: NSWorkspace.runningApplications  + .frontmostApplication
//        (Cocoa-level foreground detection — method swizzle)
// =============================================================================

static NSArray<NSRunningApplication *> *(*orig_runningApplications)(id, SEL) = NULL;
static NSRunningApplication           *(*orig_frontmostApplication)(id, SEL) = NULL;
static NSRunningApplication           *(*orig_menuBarOwningApplication)(id, SEL) = NULL;

static NSArray<NSRunningApplication *> *swz_runningApplications(id self, SEL _cmd) {
    NSArray<NSRunningApplication *> *raw = orig_runningApplications(self, _cmd);
    NSMutableArray<NSRunningApplication *> *filtered = [NSMutableArray array];
    int hidden = 0;
    for (NSRunningApplication *app in raw) {
        if (nsstring_is_ours(app.bundleIdentifier) ||
            nsstring_is_ours(app.localizedName)    ||
            nsstring_is_ours(app.executableURL.path)) {
            hidden++;
            continue;
        }
        [filtered addObject:app];
    }
    if (hidden > 0) {
        sgpt_logf("[%ld] HID %d app(s) from NSWorkspace.runningApplications",
                  (long)time(NULL), hidden);
    }
    return filtered;
}

static NSRunningApplication *swz_frontmostApplication(id self, SEL _cmd) {
    NSRunningApplication *app = orig_frontmostApplication(self, _cmd);
    if (app && (nsstring_is_ours(app.bundleIdentifier) ||
                nsstring_is_ours(app.localizedName))) {
        sgpt_logf("[%ld] LIED about frontmostApplication (was %s) — returning current process",
                  (long)time(NULL),
                  [(app.bundleIdentifier ?: @"?") UTF8String]);
        // Return the calling process itself (LDB) so LDB thinks it's
        // still frontmost.
        return [NSRunningApplication currentApplication];
    }
    return app;
}

static NSRunningApplication *swz_menuBarOwningApplication(id self, SEL _cmd) {
    NSRunningApplication *app = orig_menuBarOwningApplication(self, _cmd);
    if (app && (nsstring_is_ours(app.bundleIdentifier) ||
                nsstring_is_ours(app.localizedName))) {
        return [NSRunningApplication currentApplication];
    }
    return app;
}

/// Install method swizzles on NSWorkspace instance methods.  Called
/// from the constructor.
static void install_workspace_hooks(void) {
    Class cls = NSClassFromString(@"NSWorkspace");
    if (!cls) return;

    SEL selRunning  = @selector(runningApplications);
    SEL selFront    = @selector(frontmostApplication);
    SEL selMenuBar  = @selector(menuBarOwningApplication);

    Method mRunning = class_getInstanceMethod(cls, selRunning);
    Method mFront   = class_getInstanceMethod(cls, selFront);
    Method mMenuBar = class_getInstanceMethod(cls, selMenuBar);

    if (mRunning) {
        orig_runningApplications = (void *)method_getImplementation(mRunning);
        method_setImplementation(mRunning, (IMP)swz_runningApplications);
        sgpt_log("           hooked NSWorkspace.runningApplications");
    }
    if (mFront) {
        orig_frontmostApplication = (void *)method_getImplementation(mFront);
        method_setImplementation(mFront, (IMP)swz_frontmostApplication);
        sgpt_log("           hooked NSWorkspace.frontmostApplication");
    }
    if (mMenuBar) {
        orig_menuBarOwningApplication = (void *)method_getImplementation(mMenuBar);
        method_setImplementation(mMenuBar, (IMP)swz_menuBarOwningApplication);
        sgpt_log("           hooked NSWorkspace.menuBarOwningApplication");
    }
}

// =============================================================================
//  Constructor — log injection + install Cocoa hooks
// =============================================================================

__attribute__((constructor))
static void screengpt_dylib_load(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *bundleID = [bundle bundleIdentifier] ?: @"(none)";
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        proc_pidpath(getpid(), path, sizeof(path));

        sgpt_logf("[%ld] LOADED  pid=%d  bundleID=%s  exe=%s  → DYLD interposes installed",
                  (long)time(NULL),
                  getpid(),
                  [bundleID UTF8String],
                  path);

        // Only the Cocoa swizzles need explicit installation; the C-level
        // hooks (kill, killpg, CGWindowListCopyWindowInfo) are wired up
        // automatically via DYLD_INTERPOSE at load time.  Install Cocoa
        // hooks on the main queue so any NSObject runtime initialisation
        // is finished.
        dispatch_async(dispatch_get_main_queue(), ^{
            install_workspace_hooks();
        });
    }
}
