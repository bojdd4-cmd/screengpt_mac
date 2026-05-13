//
//  SettingsController.swift
//  ScreenGPT
//
//  Owns the NSWindow that hosts SettingsView.  Uses a normal NSWindow
//  (not the click-through NSPanel) because text fields / segmented pickers
//  need keyboard + mouse events.
//
//  The settings window binds to the shared OverlayModel so changes apply
//  to the overlay instantly.  The controller doesn't keep its own model
//  state.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsController {

    private let model: OverlayModel
    private(set) var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?

    init(sharedModel: OverlayModel) {
        self.model = sharedModel
    }

    /// Show (or bring forward) the Settings window.
    func show() {
        let win = ensureWindow()
        positionInCenter(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide without releasing.  Window can be reopened cheaply.
    func close() {
        window?.orderOut(nil)
    }

    var isShowing: Bool { window?.isVisible ?? false }

    // MARK: - Internals

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }
        let host = NSHostingController(rootView: SettingsView(
            model: model,
            onClose: { [weak self] in self?.close() }
        ))
        hosting = host

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.sharingType = .none      // invisible to outside screen capture
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(red: 0.07, green: 0.05, blue: 0.12, alpha: 1.0)
        win.contentViewController = host
        window = win
        return win
    }

    private func positionInCenter(_ win: NSWindow) {
        guard let screen = NSScreen.main else { win.center(); return }
        let frame = screen.visibleFrame
        let size = win.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + 40
        )
        win.setFrameOrigin(origin)
    }
}
