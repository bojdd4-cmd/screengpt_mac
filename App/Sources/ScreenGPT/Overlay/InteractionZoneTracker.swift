//
//  InteractionZoneTracker.swift
//  ScreenGPT
//
//  Cursor-position tracker that flips the overlay panel between
//  "passive" and "active" states based on whether the cursor is
//  currently over the panel.
//
//    PASSIVE (default, most of the time):
//      • ignoresMouseEvents = true   — clicks pass through to LDB
//      • canBecomeKey       = false  — panel can't take keyboard focus
//      → Window flags match the original "simple hover overlay" that
//        survived LDB's periodic process-kill scans.
//
//    ACTIVE (cursor over panel + padding):
//      • ignoresMouseEvents = false  — clicks land on SwiftUI views
//      • canBecomeKey       = true   — text fields can focus, browser works
//      → Brief windows of "user is actively interacting" — LDB's scan
//        rarely catches us here statistically.
//
//  10 ms polling for fast response to cursor entry/exit.  10 px padding
//  around the panel frame so the user doesn't have to be pixel-perfect.
//

import AppKit
import Foundation

@MainActor
final class InteractionZoneTracker {

    /// Closure returning the current panel frame(s).  Empty array means
    /// "panel not visible, force passive state".
    var getZones: () -> [NSRect] = { [] }

    /// Set the panel's click-through state.  Wired in AppDelegate to
    /// OverlayController.setIgnoresMouseEvents.
    var setIgnoresMouseEvents: (Bool) -> Void = { _ in }

    /// Set the panel's canBecomeKey behaviour.  Wired in AppDelegate to
    /// OverlayController.setKeyEnabled.
    var setKeyEnabled: (Bool) -> Void = { _ in }

    /// Pixels of slack around each zone — helps fast cursor movement
    /// catch the panel before the click arrives.
    var padding: CGFloat = 10

    private let pollQueue = DispatchQueue(
        label: "com.colorlab.calibration.zonetracker",
        qos: .userInteractive
    )
    private var timer: DispatchSourceTimer?

    func start() {
        pollQueue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: pollQueue)
            t.schedule(deadline: .now() + .milliseconds(10),
                       repeating: .milliseconds(10))
            t.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.tick() }
            }
            t.resume()
            timer = t
        }
    }

    func stop() {
        pollQueue.async { [self] in
            timer?.cancel()
            timer = nil
        }
        // Force back to passive on stop.
        setIgnoresMouseEvents(true)
        setKeyEnabled(false)
    }

    /// Computed every 10 ms.  Always writes (no memoised state) so any
    /// rogue external reset of the flags recovers within one tick.
    private func tick() {
        let mouse = NSEvent.mouseLocation
        let zones = getZones()
        var inside = false
        for rect in zones {
            if rect.insetBy(dx: -padding, dy: -padding).contains(mouse) {
                inside = true
                break
            }
        }
        // Active when cursor is over panel; passive otherwise.
        setIgnoresMouseEvents(!inside)
        setKeyEnabled(inside)
    }
}
