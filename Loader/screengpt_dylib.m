//
//  screengpt_dylib.m
//  ScreenGPT — injection dylib
//
//  Phase 2a: minimal visible overlay inside LockDown Browser.
//
//  Lifecycle:
//
//      1. dyld loads us into EVERY new GUI process (because we set
//         DYLD_INSERT_LIBRARIES via launchctl setenv).
//
//      2. __attribute__((constructor)) runs immediately.  We log the
//         host process info and check whether this is the target.
//
//      3. If not the target (Chrome, launchctl, LDB sub-helpers, etc.),
//         we bail cleanly — no UI, no side effects.
//
//      4. If this IS the target (com.Respondus.LockDownBrowser exactly),
//         we register an observer for
//         NSApplicationDidFinishLaunchingNotification.  We can't create
//         windows yet because NSApp isn't set up — the host's main()
//         hasn't been called.
//
//      5. When the observer fires (host's NSApplication is up), we
//         create an NSPanel and show it.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import <stdio.h>
#import <sys/types.h>
#import <sys/stat.h>

// =============================================================================
//  Logging
// =============================================================================

static void sgpt_log(NSString *msg) {
    const char *path = "/tmp/screengpt_dylib.log";
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    NSString *line = [msg stringByAppendingString:@"\n"];
    const char *bytes = [line UTF8String];
    if (bytes) write(fd, bytes, strlen(bytes));
    close(fd);
}

static NSString *sgpt_describe_host(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = [bundle bundleIdentifier] ?: @"(none)";
    NSString *exePath = [[bundle executableURL] path] ?: @"(none)";
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSString *sgptTarget = env[@"SGPT_TARGET"] ?: @"(unset)";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZ";
    return [NSString stringWithFormat:
            @"[%@] LOADED  pid=%d  bundleID=%@  exe=%@  SGPT_TARGET=%@",
            [fmt stringFromDate:[NSDate date]],
            getpid(), bundleID, exePath, sgptTarget];
}

// =============================================================================
//  Target detection
// =============================================================================

/// Decide whether to do anything in this process.
///
/// Match policy: only the main LockDown Browser process — exclude its
/// helper sub-bundles (GPU, Renderer, Alerts, etc.) because:
///   • They are sandboxed Chromium-style helper processes that can't
///     display top-level UI.
///   • They share the parent's DYLD env vars but have stricter
///     restrictions.
///   • Running our init code in N helpers wastes resources and
///     pollutes the log.
///
/// We require the bundle ID to:
///   • contain "LockDownBrowser" (case-insensitive) AND
///   • NOT contain ".helper" (case-insensitive)
static BOOL sgpt_should_activate_in_this_process(void) {
    NSString *target = [[NSProcessInfo processInfo] environment][@"SGPT_TARGET"];
    if (target.length == 0) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (bundleID.length == 0) return NO;

    // Substring match on target token first.
    if ([bundleID rangeOfString:target options:NSCaseInsensitiveSearch].location == NSNotFound)
        return NO;

    // Reject Chromium-style helper sub-bundles.
    if ([bundleID rangeOfString:@".helper" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return NO;

    return YES;
}

// =============================================================================
//  Overlay UI — minimal Phase 2a panel
// =============================================================================

static NSPanel *sgpt_panel = nil;
static id sgpt_launchObserver = nil;

/// Build and show the overlay panel.  Must run on the main thread AFTER
/// NSApp has finished launching.
static void sgpt_show_overlay(void) {
    if (sgpt_panel) {
        sgpt_log(@"           sgpt_show_overlay called but panel already exists");
        return;
    }
    sgpt_log(@"           sgpt_show_overlay — building NSPanel");

    NSRect frame = NSMakeRect(0, 0, 420, 280);
    sgpt_panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskBorderless
                                                       | NSWindowStyleMaskNonactivatingPanel)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    sgpt_panel.level = NSStatusWindowLevel;
    sgpt_panel.sharingType = NSWindowSharingNone;   // invisible to screen capture
    sgpt_panel.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces
                                     | NSWindowCollectionBehaviorStationary
                                     | NSWindowCollectionBehaviorFullScreenAuxiliary
                                     | NSWindowCollectionBehaviorIgnoresCycle);
    sgpt_panel.opaque = NO;
    sgpt_panel.backgroundColor = [NSColor clearColor];
    sgpt_panel.hasShadow = YES;
    sgpt_panel.movableByWindowBackground = YES;
    sgpt_panel.hidesOnDeactivate = NO;
    sgpt_panel.releasedWhenClosed = NO;

    // Content view: dark rounded backdrop + label
    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor colorWithRed:0.07 green:0.05 blue:0.12 alpha:0.96].CGColor;
    content.layer.cornerRadius = 18;
    content.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.12].CGColor;
    content.layer.borderWidth = 1;

    NSTextField *header = [NSTextField labelWithString:@"ScreenGPT"];
    header.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    header.textColor = [NSColor whiteColor];
    header.frame = NSMakeRect(20, 220, 380, 30);
    header.drawsBackground = NO;
    header.bordered = NO;
    [content addSubview:header];

    NSTextField *status = [NSTextField labelWithString:
                           [NSString stringWithFormat:
                            @"Injected into pid=%d\n%@",
                            getpid(),
                            [[NSBundle mainBundle] bundleIdentifier] ?: @""]];
    status.font = [NSFont systemFontOfSize:11];
    status.textColor = [NSColor colorWithWhite:1.0 alpha:0.7];
    status.frame = NSMakeRect(20, 170, 380, 40);
    status.drawsBackground = NO;
    status.bordered = NO;
    [content addSubview:status];

    NSTextField *note = [NSTextField wrappingLabelWithString:
                         @"Phase 2a — minimal in-process overlay.\n"
                         @"Confirms we can render UI inside LDB's NSApplication.\n\n"
                         @"Next: chat, scan, login, full feature parity."];
    note.font = [NSFont systemFontOfSize:12];
    note.textColor = [NSColor colorWithWhite:1.0 alpha:0.85];
    note.frame = NSMakeRect(20, 30, 380, 130);
    [content addSubview:note];

    sgpt_panel.contentView = content;

    // Centre on the main screen.
    NSScreen *screen = [NSScreen mainScreen];
    NSRect vis = screen.visibleFrame;
    NSPoint origin = NSMakePoint(NSMidX(vis) - 210, NSMidY(vis) - 140);
    [sgpt_panel setFrameOrigin:origin];

    [sgpt_panel orderFrontRegardless];

    sgpt_log([NSString stringWithFormat:
              @"           overlay panel shown — frame=%@ isVisible=%d level=%ld",
              NSStringFromRect(sgpt_panel.frame),
              (int)sgpt_panel.isVisible,
              (long)sgpt_panel.level]);
}

/// Called once the host's NSApplication has finished launching — safe
/// to create windows at this point.
static void sgpt_on_app_launched(NSNotification *note) {
    (void)note;
    sgpt_log(@"           NSApplicationDidFinishLaunchingNotification fired");
    sgpt_show_overlay();
    if (sgpt_launchObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:sgpt_launchObserver];
        sgpt_launchObserver = nil;
    }
}

// =============================================================================
//  Constructor — entrypoint when dyld loads us
// =============================================================================

/// Poll NSApp every 250ms until it's running, then show the overlay.
/// Chromium-style apps (Electron, LockDown Browser) often delay
/// NSApp.run() significantly past dylib load time, and some don't
/// reliably fire NSApplicationDidFinishLaunchingNotification.  Polling
/// avoids both problems.
static void sgpt_retry_show_overlay(int attempt) {
    @autoreleasepool {
        BOOL nsappReady = (NSApp != nil) && NSApp.isRunning;
        sgpt_log([NSString stringWithFormat:
                  @"           [retry %d] NSApp=%@ isRunning=%d mainScreen=%@",
                  attempt,
                  NSApp ? @"present" : @"nil",
                  NSApp ? (int)NSApp.isRunning : -1,
                  [NSScreen mainScreen] ? @"present" : @"nil"]);

        if (nsappReady) {
            sgpt_show_overlay();
            return;
        }

        if (attempt >= 240) {  // 240 × 250ms = 60s give-up
            sgpt_log(@"           [retry] gave up after 60s, NSApp never ready");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            sgpt_retry_show_overlay(attempt + 1);
        });
    }
}

__attribute__((constructor))
static void screengpt_dylib_load(void) {
    @autoreleasepool {
        sgpt_log(sgpt_describe_host());

        if (!sgpt_should_activate_in_this_process()) {
            sgpt_log(@"           → not target, exiting constructor cleanly");
            return;
        }
        sgpt_log(@"           → TARGET MATCH, scheduling overlay setup (poll-based)");

        // Schedule on main queue.  First tick runs as soon as the run
        // loop is processing dispatch events.
        dispatch_async(dispatch_get_main_queue(), ^{
            sgpt_retry_show_overlay(0);
        });
    }
}
