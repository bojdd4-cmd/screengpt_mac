//
//  OverlayDefender.swift
//  ScreenGPT
//
//  Continuous-defense layer that fights LDB's attempts to hide the
//  overlay during exam mode.  Symptoms on macOS:
//
//   • LDB enters its own fullscreen Space — our overlay sometimes
//     doesn't follow even with .canJoinAllSpaces.
//   • LDB activates itself and its window level claims dominance —
//     our overlay disappears behind LDB even at CGShieldingWindowLevel.
//   • LDB calls hideOtherApplications — apps with .regular activation
//     policy get hidden.
//
//  Defense in this file:
//
//   1. Every 250 ms, re-set the window level (currently `.statusBar`
//      = 25, blends in with menu-bar utilities) and call
//      orderFrontRegardless.  If LDB pushed us back or lowered our
//      level, we bounce up.
//
//   2. Optional diagnostics (CALIB_DIAGNOSTICS=1) — every 2 s,
//      enumerate every visible window via CGWindowListCopyWindowInfo
//      and log owner + level.  Tells us exactly what LDB is doing,
//      so we know which level to fight at.
//
//  All work runs on the main thread because NSWindow APIs require it.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class OverlayDefender {

    // MARK: - Configuration

    /// How often we re-assert window level + ordering.
    /// 250 ms is fast enough that a hidden overlay is back in <0.25 s,
    /// slow enough that the CPU cost is negligible (~4 calls/sec).
    static let assertIntervalMs: Int = 250

    /// How often we dump the visible-window list when diagnostics is on.
    static let diagnosticsIntervalSec: TimeInterval = 2.0

    /// The level we re-assert to.  We use `.statusBar` (raw value 25) to
    /// blend in with menu-bar utilities like Bartender / Hyperdock, which
    /// commonly hover above normal app windows during fullscreen apps.
    ///
    /// Earlier attempts at CGMaximumWindowLevel (2147483631) likely tripped
    /// an LDB heuristic that flags any window above level N as a cheat
    /// overlay — we were extreme outliers.  At `.statusBar` we sit in a
    /// crowd of legitimate menu-bar items, far harder to fingerprint.
    ///
    /// Trade-off: LDB itself may render above us if it uses a higher
    /// level.  If that happens, the overlay is visually covered (cursor
    /// dwell still works because that polls global mouse, not focus).
    /// Future tuning may move us back up to `.popUpMenu` (101) or
    /// `.modalPanel` (8) depending on what surfaces best.
    static var assertedLevel: NSWindow.Level { .statusBar }

    // MARK: - State

    private weak var controller: OverlayController?
    private var assertTimer: Timer?
    private var diagnosticsTimer: Timer?
    private var running = false

    /// Tracks how many times in a row each window failed the visibility
    /// check (e.g. wasn't in the on-screen window list).  Reset when the
    /// window comes back.  Used purely for diagnostic logging — if a window
    /// stays hidden for >2 ticks we log it loudly.
    private var consecutiveHiddenTicks: [Int: Int] = [:]

    /// Set true to enable the chatty window-list dump every 2 s.
    let diagnosticsEnabled: Bool

    init(controller: OverlayController) {
        self.controller = controller
        self.diagnosticsEnabled = ProcessInfo.processInfo
            .environment["CALIB_DIAGNOSTICS"] == "1"
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true

        Log.write("OverlayDefender starting — "
            + "asserted level: \(Self.assertedLevel.rawValue), "
            + "diagnostics: \(diagnosticsEnabled)")

        // Re-assertion timer.  Use a RunLoop timer on the main thread so
        // it interleaves with AppKit's event loop cleanly.
        assertTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(Self.assertIntervalMs) / 1000.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.assertTick() }
        }

        if diagnosticsEnabled {
            diagnosticsTimer = Timer.scheduledTimer(
                withTimeInterval: Self.diagnosticsIntervalSec,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.diagnosticsTick() }
            }
        }
    }

    func stop() {
        assertTimer?.invalidate(); assertTimer = nil
        diagnosticsTimer?.invalidate(); diagnosticsTimer = nil
        running = false
        Log.write("OverlayDefender stopped.")
    }

    // MARK: - Assertion tick

    private func assertTick() {
        guard let controller else { return }
        controller.reassertProtection()

        // Check whether each window is actually in the on-screen list.
        // If not, it's been hidden by another process (likely LDB).
        let onScreen = currentOnScreenWindowNumbers()

        for window in controller.allOverlayWindows {
            guard window.isVisible else { continue }
            let num = window.windowNumber
            let visible = onScreen.contains(num)
            let key = num
            if visible {
                consecutiveHiddenTicks.removeValue(forKey: key)
            } else {
                let n = (consecutiveHiddenTicks[key] ?? 0) + 1
                consecutiveHiddenTicks[key] = n
                if n == 2 {
                    // First time it's been hidden for 2 ticks (500 ms) —
                    // log it once.  Don't spam if it stays hidden.
                    Log.write("⚠️  window #\(num) hidden by another process; "
                        + "force-ordering back to front")
                }
                // Force back to front.
                window.orderFrontRegardless()
            }
        }
    }

    private func currentOnScreenWindowNumbers() -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var nums = Set<Int>()
        for w in list {
            if let n = w[kCGWindowNumber as String] as? Int {
                nums.insert(n)
            }
        }
        return nums
    }

    // MARK: - Diagnostics tick

    private func diagnosticsTick() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]
        else {
            Log.write("[diagnostics] CGWindowListCopyWindowInfo returned nil")
            return
        }

        // Compact summary: just LDB / Respondus / our-own windows plus
        // anything at unusually high levels.  Full dump would be huge.
        var relevant: [String] = []
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            let level = (w[kCGWindowLayer as String] as? Int) ?? -1
            let name  = (w[kCGWindowName as String] as? String) ?? ""
            let pid   = (w[kCGWindowOwnerPID as String] as? Int) ?? -1

            let lower = owner.lowercased()
            let isInteresting =
                lower.contains("lockdown")     ||
                lower.contains("respondus")    ||
                lower.contains("calibration")  ||
                level >= 1000   // anything above status-bar level

            if isInteresting {
                relevant.append(
                    "    pid=\(pid)  level=\(level)  owner=\"\(owner)\""
                    + (name.isEmpty ? "" : "  name=\"\(name)\"")
                )
            }
        }
        Log.write("[diagnostics] visible windows of interest:\n"
            + (relevant.isEmpty ? "    (none)" : relevant.joined(separator: "\n")))
    }
}
