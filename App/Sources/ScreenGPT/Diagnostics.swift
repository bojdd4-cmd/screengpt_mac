//
//  Diagnostics.swift
//  ScreenGPT
//
//  Death-cause diagnostics.  We've observed LDB killing the ScreenGPT
//  process when an exam starts, but we don't know HOW — SIGTERM, SIGKILL,
//  AppleEvent quit, or something else.  This file installs signal handlers
//  + an AppleEvent quit detector so the next exam run logs the cause.
//
//  Key constraint: signal handlers must use ONLY async-signal-safe
//  operations (per POSIX).  That means:
//     • No Swift dynamic allocation
//     • No locks
//     • Only `write(2)`, `_exit(2)`, etc.
//     • No `Date()`, no `print`, no `Log.write` (which uses Foundation +
//       locks).
//
//  Strategy:
//     • Pre-build the message as a `StaticString` (compile-time, no alloc).
//     • Write directly to the logfile via the cached file descriptor.
//     • Re-raise the signal with default disposition so the kernel
//       actually terminates us (otherwise we'd loop forever).
//

import Darwin
import Foundation
import AppKit

// =============================================================================
//  Shared file descriptor used by the signal handler.
//
//  We can't safely access Swift singletons (like Log.fileHandle) from inside
//  the signal handler, so we cache the raw FD at startup.  `nonisolated(unsafe)`
//  acknowledges this is shared across actors without synchronisation — but
//  we only WRITE to it once at startup, before any signal can fire.
// =============================================================================

nonisolated(unsafe) var screengptLogFD: Int32 = STDERR_FILENO

// =============================================================================
//  Pre-built UTF-8 messages — StaticString is compile-time, no allocation.
// =============================================================================

private let MSG_SIGTERM: StaticString =
    "[FATAL-SIGNAL] received SIGTERM — polite kill from another process\n"
private let MSG_SIGINT: StaticString =
    "[FATAL-SIGNAL] received SIGINT — ctrl-C or interrupt\n"
private let MSG_SIGHUP: StaticString =
    "[FATAL-SIGNAL] received SIGHUP — controlling terminal closed\n"
private let MSG_SIGQUIT: StaticString =
    "[FATAL-SIGNAL] received SIGQUIT — quit signal\n"
private let MSG_SIGPIPE: StaticString =
    "[FATAL-SIGNAL] received SIGPIPE — broken pipe (brain may be dead)\n"
private let MSG_SIGUSR1: StaticString =
    "[FATAL-SIGNAL] received SIGUSR1\n"
private let MSG_SIGUSR2: StaticString =
    "[FATAL-SIGNAL] received SIGUSR2\n"
private let MSG_UNKNOWN: StaticString =
    "[FATAL-SIGNAL] received unknown signal\n"

// =============================================================================
//  The C-function-pointer signal handler.
// =============================================================================
//
//  @convention(c) closures can't capture Swift context, so we must access
//  the FD via the global `screengptLogFD`.
//

private let signalHandler: @convention(c) (Int32) -> Void = { signum in
    let msg: StaticString
    switch signum {
    case SIGTERM: msg = MSG_SIGTERM
    case SIGINT:  msg = MSG_SIGINT
    case SIGHUP:  msg = MSG_SIGHUP
    case SIGQUIT: msg = MSG_SIGQUIT
    case SIGPIPE: msg = MSG_SIGPIPE
    case SIGUSR1: msg = MSG_SIGUSR1
    case SIGUSR2: msg = MSG_SIGUSR2
    default:      msg = MSG_UNKNOWN
    }

    let ptr = msg.utf8Start
    let len = msg.utf8CodeUnitCount

    // Write to stderr (terminal may not be visible during LDB) AND to the
    // logfile fd.  Both are async-signal-safe operations.
    _ = write(STDERR_FILENO, ptr, len)
    let fd = screengptLogFD
    if fd != STDERR_FILENO && fd >= 0 {
        _ = write(fd, ptr, len)
    }

    // Re-raise with default disposition so we actually terminate.
    // (Without this we'd return into the program counter that was running
    // when the signal arrived, which is usually fine but inconsistent.)
    signal(signum, SIG_DFL)
    raise(signum)
}

// =============================================================================
//  Public entry point — call once at app launch.
// =============================================================================

enum Diagnostics {

    /// Install the suite of diagnostic hooks.  Idempotent — safe to call
    /// multiple times.  Call this BEFORE `NSApplication.run()` so the
    /// handlers are in place from the very first instruction the run loop
    /// executes.
    static func install() {
        // 1. Cache the logfile FD for signal-handler use.
        let fd = Log.fileDescriptor
        if fd >= 0 {
            screengptLogFD = fd
        }

        // 2. Register handlers for every signal LDB might use.
        //    We can't catch SIGKILL or SIGSTOP — by OS design.  If we get
        //    killed without any of these messages appearing in the log,
        //    that's the strong signal LDB used SIGKILL.
        signal(SIGTERM, signalHandler)
        signal(SIGINT,  signalHandler)
        signal(SIGHUP,  signalHandler)
        signal(SIGQUIT, signalHandler)
        signal(SIGPIPE, signalHandler)
        signal(SIGUSR1, signalHandler)
        signal(SIGUSR2, signalHandler)

        Log.write("[Diagnostics] signal handlers installed; pid=\(getpid())")
    }

    /// Inspect `NSAppleEventManager.currentAppleEvent` and log a description
    /// of what triggered the current AppleEvent dispatch (if any).  Used
    /// from `applicationShouldTerminate(_:)` to detect AppleEvent quits.
    @MainActor
    static func describeCurrentAppleEvent() -> String {
        guard let evt = NSAppleEventManager.shared().currentAppleEvent else {
            return "no current AppleEvent (likely programmatic terminate)"
        }
        let cls = evt.eventClass
        let id  = evt.eventID
        let classStr = fourCharCode(cls)
        let idStr    = fourCharCode(id)
        var info = "class=\(classStr) id=\(idStr)"
        // Try to extract the sender bundle ID.
        if let addr = evt.attributeDescriptor(forKeyword: keyAddressAttr) {
            if let bid = addr.stringValue {
                info += " bundleID=\"\(bid)\""
            } else if addr.descriptorType == typeKernelProcessID {
                let pid = addr.int32Value
                info += " pid=\(pid)"
            }
        }
        return info
    }

    /// Convert a FourCharCode (AppleEvent class/id) like 'quit' to a 4-char
    /// ASCII string.  Used only for log readability.
    private static func fourCharCode(_ code: FourCharCode) -> String {
        let b0 = UInt8((code >> 24) & 0xFF)
        let b1 = UInt8((code >> 16) & 0xFF)
        let b2 = UInt8((code >>  8) & 0xFF)
        let b3 = UInt8( code        & 0xFF)
        let bytes = [b0, b1, b2, b3]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(format: "0x%08X", code)
    }
}
