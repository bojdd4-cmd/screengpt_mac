//
//  DwellMonitor.swift
//  ScreenGPT
//
//  100 Hz cursor-position polling for hover-dwell activation.  Mirrors
//  hook.cpp's InputThread (lines 1567-1832) — the exact same model:
//
//    • Poll NSEvent.mouseLocation every 10 ms (no event listener — never
//      steals focus from LDB).
//    • Hit-test against the currently-registered button rects.
//    • When the cursor enters a button, start a dwell timer.
//    • Report 0.0 → 1.0 progress via `onProgress` for the SwiftUI fill bar.
//    • When elapsed >= dwellMs, fire `onActivate` and reset (for held-button
//      repeats like scroll arrows, the next activation fires after the
//      shorter `repeatScrollDwellMs` interval).
//
//  Concurrency:
//    All state lives on `pollQueue` (a serial DispatchQueue).  Public
//    setters dispatch to the queue.  Callbacks (`onActivate`, `onProgress`)
//    are dispatched to the main actor for the UI.
//

import AppKit
import Foundation

final class DwellMonitor: @unchecked Sendable {

    // MARK: - Types

    struct Button: Sendable {
        let id: ButtonID
        let rect: NSRect               // SCREEN coordinates, bottom-up
        /// First-activation dwell. Defaults to 1500 ms (matches Windows
        /// HOVER_MS).
        let dwellMs: Int

        init(id: ButtonID, rect: NSRect, dwellMs: Int = DwellMonitor.defaultDwellMs) {
            self.id = id
            self.rect = rect
            self.dwellMs = dwellMs
        }
    }

    static let defaultDwellMs       = 1500
    static let firstScrollDwellMs   = 400
    static let repeatScrollDwellMs  = 200

    // MARK: - Public API

    /// Fires every tick a button is hovered. `progress` is in [0, 1].
    /// Fires `(buttonID, 0)` once when the cursor leaves a button so the UI
    /// can clear the fill bar.
    /// Invoked on the main actor.
    var onProgress: (@MainActor (ButtonID, Double) -> Void)?

    /// Fires when `progress` reaches 1.0.  After firing, the dwell timer
    /// resets — held buttons will re-fire at `repeatScrollDwellMs`.
    /// Invoked on the main actor.
    var onActivate: (@MainActor (ButtonID) -> Void)?

    // MARK: - State (touched only on pollQueue)

    private let pollQueue = DispatchQueue(
        label: "com.colorlab.calibration.dwell",
        qos: .userInteractive
    )
    private var timer: DispatchSourceTimer?

    private var buttons: [Button] = []

    private var currentHover: ButtonID? = nil
    private var hoverStart: TimeInterval = 0
    private var activationsThisHover: Int = 0

    // MARK: - Lifecycle

    func start() {
        pollQueue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: pollQueue)
            t.schedule(deadline: .now() + .milliseconds(10),
                       repeating: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        pollQueue.async { [self] in
            timer?.cancel()
            timer = nil
            buttons.removeAll()
            currentHover = nil
            hoverStart = 0
            activationsThisHover = 0
        }
    }

    func setButtons(_ b: [Button]) {
        pollQueue.async { [self] in
            buttons = b
        }
    }

    // MARK: - Tick (runs on pollQueue)

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime

        let hit = buttons.first { $0.rect.contains(mouse) }

        if let btn = hit {
            // Entered a new button — reset.
            if currentHover != btn.id {
                currentHover = btn.id
                hoverStart = now
                activationsThisHover = 0
            }
            let elapsedMs = (now - hoverStart) * 1000.0
            let dwellMs   = effectiveDwell(for: btn, activations: activationsThisHover)
            let progress  = min(1.0, elapsedMs / Double(dwellMs))

            let id = btn.id
            let p  = progress
            let onProgress = self.onProgress
            DispatchQueue.main.async {
                onProgress?(id, p)
            }

            if elapsedMs >= Double(dwellMs) {
                activationsThisHover += 1
                hoverStart = now
                let onActivate = self.onActivate
                DispatchQueue.main.async {
                    onActivate?(id)
                }
            }
        } else {
            // No button under cursor — clear any pending fill bar.
            if let prev = currentHover {
                let onProgress = self.onProgress
                DispatchQueue.main.async {
                    onProgress?(prev, 0)
                }
            }
            currentHover = nil
            hoverStart = 0
            activationsThisHover = 0
        }
    }

    /// First activation uses the button's `dwellMs`.  Subsequent activations
    /// (held cursor on scroll buttons) use the faster repeat cadence.
    private func effectiveDwell(for btn: Button, activations: Int) -> Int {
        switch btn.id {
        case .scrollUp, .scrollDown:
            if activations == 0 { return Self.firstScrollDwellMs }
            return Self.repeatScrollDwellMs
        default:
            return btn.dwellMs
        }
    }
}
