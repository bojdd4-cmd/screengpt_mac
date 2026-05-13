//
//  LoginController.swift
//  ScreenGPT
//
//  Owns the NSWindow that hosts LoginView.  Uses a normal NSWindow (not
//  the click-through NSPanel) because text fields must accept keyboard
//  input.  The window is borderless + draggable-by-content, dark themed,
//  and shows over LDB just like the overlay does.
//
//  Lifecycle:
//      • AppDelegate creates a LoginController once at startup.
//      • Calls `show()` after the brain emits `ready` (unless we have a
//        cached token to auto-login with).
//      • Calls `close()` after `login_ok` arrives.
//      • Error messages come back via `setError(_:)` from the
//        `login_err` branch of handleBrainEvent.
//

import AppKit
import SwiftUI

@MainActor
final class LoginController {

    let model = LoginModel()

    private(set) var window: NSWindow?
    private var hosting: NSHostingController<LoginView>?

    // MARK: - Public

    /// Build (lazily) and show the login window.  Brings the app forward
    /// briefly so the text fields receive keyboard input.  The app is
    /// .accessory so no Dock icon appears even though we activate.
    func show() {
        let win = ensureWindow()
        positionInCenter(win)
        win.makeKeyAndOrderFront(nil)
        // Briefly activate so the SecureField actually receives key events.
        // An .accessory app stays Dock-iconless even after activate().
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        // Wipe password from memory immediately on close.
        model.password = ""
        model.isSubmitting = false
        model.errorMessage = nil
    }

    func setError(_ msg: String) {
        model.errorMessage = msg
        model.isSubmitting = false
    }

    /// True if the window is currently on screen.
    var isShowing: Bool { window?.isVisible ?? false }

    // MARK: - Internals

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }

        let host = NSHostingController(rootView: LoginView(model: model))
        hosting = host

        // .titled gives us a draggable area + close button.  .fullSizeContentView
        // lets the SwiftUI backdrop extend under the title bar so the brand
        // colour reads as a single rectangle.  Closable so the user can
        // dismiss without logging in (we treat that as "no token, retry
        // on next launch").
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating          // float above LDB
        win.sharingType = .none        // invisible to capture (defense-in-depth)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(red: 0.07, green: 0.05, blue: 0.12, alpha: 1.0)
        win.contentViewController = host

        // Closing the window via the red X behaves the same as dismissing —
        // we wipe the password and stop accepting events.  The app stays
        // alive in case the user wants to re-show via hotkey later.
        let delegate = LoginWindowDelegate(owner: self)
        win.delegate = delegate
        self.delegateRetain = delegate

        window = win
        return win
    }

    private func positionInCenter(_ win: NSWindow) {
        guard let screen = NSScreen.main else { win.center(); return }
        let frame = screen.visibleFrame
        let size = win.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + 40   // bias slightly upward
        )
        win.setFrameOrigin(origin)
    }

    // Strong reference so the delegate isn't deallocated while the window
    // is showing (NSWindow holds delegate weakly).
    private var delegateRetain: NSWindowDelegate?

    // Nested helper — NSWindow.delegate is an Objective-C runtime hook so
    // it can't sit on the @MainActor class directly without ceremonies.
    private final class LoginWindowDelegate: NSObject, NSWindowDelegate {
        weak var owner: LoginController?
        init(owner: LoginController) { self.owner = owner }
        func windowWillClose(_ notification: Notification) {
            owner?.model.password = ""
            owner?.model.isSubmitting = false
        }
    }
}
