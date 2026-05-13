//
//  InteractionZoneTracker.swift
//  ScreenGPT
//
//  The killer-feature: panel-wide click-through with selective interaction
//  zones.  The NSPanel's `ignoresMouseEvents` flips 50× per second based on
//  whether the cursor is currently over an interactive control rect.
//
//  Click happens INSIDE a zone     → panel captures it, SwiftUI Button fires
//  Click happens OUTSIDE all zones → panel ignores it, click passes through
//                                    to whatever's beneath (LockDown, your
//                                    text editor, etc.)
//
//  Mirrors CloakGPT's "always click-through except on the chrome" behaviour.
//
//  Zones are screen-coordinate rects.  AppDelegate computes them every tick
//  based on the panel's current frame + UI state (browser open?, dropdown
//  open?).  We expand each zone by `padding` pixels so a fast click that
//  arrives a millisecond before the cursor visually enters the zone still
//  lands.
//

import AppKit
import Foundation

@MainActor
final class InteractionZoneTracker {

    /// Closure providing the current interactive zones in screen coords.
    /// Refreshed every tick — must be fast.
    var getZones: () -> [NSRect] = { [] }

    /// Called when the click-through state should flip.  AppDelegate hooks
    /// this to `panelWindow.ignoresMouseEvents = value`.
    var setIgnoresMouseEvents: (Bool) -> Void = { _ in }

    /// Expand each zone by this many pixels — buffers fast clicks that land
    /// a moment before the cursor visually enters the chrome.
    var padding: CGFloat = 4

    private let pollQueue = DispatchQueue(
        label: "com.colorlab.calibration.zonetracker",
        qos: .userInteractive
    )
    private var timer: DispatchSourceTimer?
    private var lastIgnore: Bool = true   // start click-through

    func start() {
        pollQueue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: pollQueue)
            t.schedule(deadline: .now() + .milliseconds(10),
                       repeating: .milliseconds(20))
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
        // Reset to interactive when we stop, so subsequent UI changes work
        // even if no zone is being tracked.
        setIgnoresMouseEvents(false)
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let zones = getZones()
        var inside = false
        for rect in zones {
            let padded = rect.insetBy(dx: -padding, dy: -padding)
            if padded.contains(mouse) { inside = true; break }
        }
        let shouldIgnore = !inside
        if shouldIgnore != lastIgnore {
            lastIgnore = shouldIgnore
            setIgnoresMouseEvents(shouldIgnore)
        }
    }
}
