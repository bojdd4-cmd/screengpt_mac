//
//  screengpt_dylib.m
//  ScreenGPT — injection dylib
//
//  Phase 1: prove DYLD_INSERT_LIBRARIES injection works on this Mac.
//  Loaded by dyld at process start when DYLD_INSERT_LIBRARIES env var
//  points to this file.  Constructor runs as soon as the dynamic linker
//  finishes loading us into the target process (LockDown Browser, etc).
//
//  In Phase 1 we just write a line to /tmp/screengpt_dylib.log so the
//  user can confirm we got loaded.  Phase 2 replaces this with the
//  actual overlay + scan UI.
//
//  Build:
//      ./build_dylib.sh
//
//  Use:
//      ./arm.sh    # sets env vars + kills LDB so next launch loads us
//      # (manually launch LDB)
//      ./disarm.sh # removes env vars so future LDB launches are clean
//
//  Requirements:
//      • SIP disabled
//      • AMFI disabled (boot-arg amfi_get_out_of_my_way=1)
//      • dylib ad-hoc signed (or properly signed)
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <stdio.h>
#import <sys/types.h>
#import <sys/stat.h>

/// Append a line to /tmp/screengpt_dylib.log.  Uses POSIX file APIs
/// rather than NSFileHandle so the open+write+close is atomic and
/// doesn't depend on Foundation's RunLoop state at constructor time.
static void sgpt_log(NSString *msg) {
    const char *path = "/tmp/screengpt_dylib.log";
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    NSString *line = [msg stringByAppendingString:@"\n"];
    const char *bytes = [line UTF8String];
    if (bytes) write(fd, bytes, strlen(bytes));
    close(fd);
}

/// Identify the host process by looking at NSBundle.main and a few
/// environment variables.  This is what runs INSIDE LDB (or whatever
/// process dyld injected us into).
static NSString *sgpt_describe_host(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = [bundle bundleIdentifier] ?: @"(none)";
    NSString *exePath = [[bundle executableURL] path] ?: @"(none)";

    NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];
    NSString *sgptTarget   = env[@"SGPT_TARGET"]   ?: @"(unset)";
    NSString *sgptInline   = env[@"SGPT_INLINE_UI"] ?: @"(unset)";
    NSString *dyldInsert   = env[@"DYLD_INSERT_LIBRARIES"] ?: @"(unset)";

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZ";
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];

    return [NSString stringWithFormat:
            @"[%@] LOADED  pid=%d  bundleID=%@  exe=%@\n"
            @"           SGPT_TARGET=%@  SGPT_INLINE_UI=%@\n"
            @"           DYLD_INSERT_LIBRARIES=%@",
            timestamp, getpid(), bundleID, exePath,
            sgptTarget, sgptInline, dyldInsert];
}

/// Decide whether to do anything in this process.  When we set
/// DYLD_INSERT_LIBRARIES via launchctl setenv, EVERY new GUI process
/// inherits it — Finder, Safari, our launcher, etc.  We only want to
/// activate inside the target.
static BOOL sgpt_should_activate_in_this_process(void) {
    NSString *target = [[NSProcessInfo processInfo] environment][@"SGPT_TARGET"];
    if (target.length == 0) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *exePath  = [[[NSBundle mainBundle] executableURL] path] ?: @"";

    // Match by bundle ID first (e.g. "com.respondus.lockdownbrowser"),
    // then fall back to executable path substring (e.g. "LockDownBrowser",
    // "Examplify").  Case-insensitive both ways.
    if ([bundleID rangeOfString:target options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    if ([exePath  rangeOfString:target options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    return NO;
}

__attribute__((constructor))
static void screengpt_dylib_load(void) {
    @autoreleasepool {
        // Log every load so we can see which processes inherited
        // DYLD_INSERT_LIBRARIES — useful for debugging.
        NSString *describe = sgpt_describe_host();
        sgpt_log(describe);

        if (!sgpt_should_activate_in_this_process()) {
            sgpt_log(@"           → not target, exiting constructor cleanly");
            return;
        }

        sgpt_log(@"           → TARGET MATCH, would init overlay here (Phase 2)");

        // Phase 2: replace this with actual UI setup.  For now, just a
        // marker so we know the injection took effect inside LDB
        // specifically.
    }
}
