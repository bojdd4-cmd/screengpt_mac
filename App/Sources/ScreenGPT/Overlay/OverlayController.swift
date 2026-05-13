//
//  OverlayController.swift
//  ScreenGPT
//
//  Owns the two NSPanels that comprise the overlay:
//
//     panelWindow   — main answer panel.  480×320, parked in the
//                     user-selected corner of the main screen.
//     bubbleWindow  — small floating answer near the cursor.  Lives at
//                     (-BUB_W, -BUB_H) off-screen when not active.
//
//  Both windows are configured with the same protection flags:
//     - level             = .statusBar (25, blends with menu-bar utilities)
//     - sharingType       = .none      (invisible to screen capture)
//     - ignoresMouseEvents = true      (click-through)
//     - styleMask          includes .nonactivatingPanel — doesn't steal focus
//     - collectionBehavior includes .canJoinAllSpaces + .fullScreenAuxiliary
//
//  Why NSPanel + .nonactivatingPanel instead of NSWindow:
//     LDB on Mac calls something like NSApp.hide(_:) on other "regular"
//     applications when it activates.  NSPanel with .nonactivatingPanel
//     belongs to an .accessory app and ignores those calls.  Combined
//     with the OverlayDefender re-assertion timer, this keeps the overlay
//     visible across LDB launch + Space switches + fullscreen transitions.
//
//  Per the macOS plan, BOTH windows can be visible simultaneously.  Toggling
//  one does not affect the other.
//

import AppKit
import SwiftUI

@MainActor
final class OverlayController {

    // MARK: - Windows

    private(set) var panelWindow:  NSPanel?
    private(set) var bubbleWindow: NSPanel?

    private var panelHost:  NSHostingController<PlaceholderPanelView>?
    private var bubbleHost: NSHostingController<PlaceholderBubbleView>?

    /// Tracks the SwiftUI model state for the placeholder views.  Week 3
    /// replaces this with a proper ObservableObject shared with the
    /// production views.
    private let model = OverlayModel()

    // MARK: - Public surface

    var panelFrame: NSRect { panelWindow?.frame ?? .zero }
    var bubbleFrame: NSRect { bubbleWindow?.frame ?? .zero }

    /// Every overlay window we manage — used by OverlayDefender to
    /// re-assert visibility on each one.
    var allOverlayWindows: [NSPanel] {
        [panelWindow, bubbleWindow].compactMap { $0 }
    }

    /// Create both windows up front so the first `setPanelVisible(true)` is
    /// instant.  Called once from AppDelegate.applicationDidFinishLaunching.
    func preload() {
        _ = ensurePanelWindow()
        _ = ensureBubbleWindow()
    }

    func setPanelVisible(_ visible: Bool) {
        let win = ensurePanelWindow()
        if visible {
            positionInCorner(win, corner: model.corner, size: panelSize)
            applyProtection(win)            // re-apply right before show
            win.orderFrontRegardless()
            // Collapsing the dropdown on hide → re-show feels natural.
            model.providerDropdownExpanded = false
        } else {
            win.orderOut(nil)
            // Always collapse the dropdown when hiding — otherwise the
            // user re-summons and the dropdown is still open with stale
            // hover state.
            model.providerDropdownExpanded = false
        }
    }

    /// Flip the panel's visibility.  Hooked up to the ⌘⇧S global hotkey.
    /// Bubble visibility is left untouched — only the main panel toggles.
    func togglePanel() {
        let win = ensurePanelWindow()
        if win.isVisible {
            setPanelVisible(false)
        } else {
            setPanelVisible(true)
        }
    }

    /// True iff the main panel is currently on screen.
    var isPanelVisible: Bool { panelWindow?.isVisible ?? false }

    /// True iff the provider dropdown is currently expanded.  AppDelegate
    /// reads this when rebuilding the dwell hit-rects so the option rows
    /// only become hot when the dropdown is showing.
    var isDropdownExpanded: Bool { model.providerDropdownExpanded }

    /// Read-only accessors for the current theme + transparency + activation.
    var modelThemeMode:        ThemeMode        { model.themeMode }
    var modelTransparencyMode: TransparencyMode { model.transparencyMode }
    var modelActivationMode:   ActivationMode   { model.activationMode }
    var modelResponseMode:     Int              { model.responseMode }
    var modelCurrentProvider:  Provider         { model.currentProvider }

    /// Set the activation mode and propagate to the SwiftUI views.  The
    /// fill bars on Capture / Provider pill / scroll arrows render only
    /// when `model.activationMode.hoverEnabled` is true.
    func setActivationMode(_ mode: ActivationMode) {
        model.activationMode = mode
    }

    func setResponseMode(_ raw: Int) {
        model.responseMode = max(0, min(2, raw))
    }

    func setBubbleVisible(_ visible: Bool) {
        let win = ensureBubbleWindow()
        if visible {
            // Park near the cursor on first show; AppDelegate moves it as
            // the answer comes back.
            let p = NSEvent.mouseLocation
            win.setFrameOrigin(NSPoint(x: p.x + 18, y: p.y - bubbleSize.height - 18))
            applyProtection(win)
            win.orderFrontRegardless()
        } else {
            win.orderOut(nil)
        }
    }

    /// Called by OverlayDefender every 250 ms.  Re-applies the protection
    /// flags + bumps each visible window back to the front in case LDB
    /// pushed it down.
    func reassertProtection() {
        if let win = panelWindow, win.isVisible {
            applyProtection(win)
            win.orderFrontRegardless()
        }
        if let win = bubbleWindow, win.isVisible {
            applyProtection(win)
            win.orderFrontRegardless()
        }
    }

    func setAnswer(_ text: String) {
        model.answer = text
    }

    func updateHoverProgress(buttonID: ButtonID, progress: Double) {
        model.hoverButton = buttonID
        model.hoverProgress = progress
    }

    /// Called by DwellMonitor when the cursor leaves any tracked button.
    /// Without this the answer panel keeps the stale hover highlight.
    func clearHover() {
        model.hoverButton = nil
        model.hoverProgress = 0
    }

    func toggleProviderDropdown() {
        model.providerDropdownExpanded.toggle()
    }

    func collapseProviderDropdown() {
        model.providerDropdownExpanded = false
    }

    func scrollAnswer(by delta: CGFloat) {
        model.scrollOffset = max(0, model.scrollOffset + delta)
    }

    /// Mirror the brain's stored provider into the dropdown UI.  AppDelegate
    /// calls this on settings load and whenever the user picks a different
    /// provider from the dropdown.
    func setCurrentProvider(_ p: Provider) {
        model.currentProvider = p
    }

    /// Flip the "scanning" indicator that the capture button uses to swap
    /// between "Hover to scan" and "Scanning…".
    func setScanning(_ scanning: Bool) {
        model.isScanning = scanning
    }

    /// Set or clear a small status banner overlaid on the answer area.
    /// Pass nil to dismiss.
    func setStatusBanner(_ text: String?) {
        model.statusBanner = text
    }

    /// Flag passed in from AppDelegate after login succeeds.  The model
    /// uses this elsewhere (week 4) to gate scan + dropdown interactions.
    func setLoggedIn(_ loggedIn: Bool) {
        model.isLoggedIn = loggedIn
    }

    // MARK: - Internals

    private let panelSize  = NSSize(width: ButtonRects.panelW, height: ButtonRects.panelH)
    private let bubbleSize = NSSize(width: 420, height: 320)

    private func ensurePanelWindow() -> NSPanel {
        if let w = panelWindow { return w }

        let host = NSHostingController(rootView: PlaceholderPanelView(model: model))
        let w = makeOverlayPanel(size: panelSize)
        w.contentViewController = host
        panelWindow = w
        panelHost   = host
        return w
    }

    private func ensureBubbleWindow() -> NSPanel {
        if let w = bubbleWindow { return w }

        let host = NSHostingController(rootView: PlaceholderBubbleView(model: model))
        let w = makeOverlayPanel(size: bubbleSize)
        w.contentViewController = host
        // Park off-screen until activated.
        w.setFrameOrigin(NSPoint(x: -bubbleSize.width, y: -bubbleSize.height))
        bubbleWindow = w
        bubbleHost   = host
        return w
    }

    /// Build a new overlay NSPanel with all the LDB-survival flags applied.
    /// The OverlayDefender re-applies a subset of these (level, ordering)
    /// every 250 ms via `applyProtection`.
    private func makeOverlayPanel(size: NSSize) -> NSPanel {
        // .nonactivatingPanel — doesn't bring our app forward when shown,
        //   so LDB stays the frontmost app and "hide other apps" semantics
        //   target someone else, not us.
        // .borderless — no titlebar, just our SwiftUI content.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Float above all other windows in the app — but the real "above
        // LDB" magic happens via window.level below.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true   // never steal keyboard focus
        panel.hidesOnDeactivate = false       // stay visible when LDB activates
        panel.worksWhenModal = true           // visible even over modal sheets

        applyProtection(panel)

        panel.isOpaque         = false
        panel.backgroundColor  = .clear
        panel.hasShadow        = false
        // Initial transparency follows the model's current TransparencyMode
        // so panel creation respects the user's preference from the start.
        panel.alphaValue       = CGFloat(model.transparencyMode.alpha)
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        // Initial appearance follows the model's current ThemeMode.
        panel.appearance       = (model.themeMode == .dark)
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)

        return panel
    }

    /// Apply the runtime-mutable protection flags.  Called once at window
    /// creation AND every 250 ms by OverlayDefender — LDB may try to mutate
    /// these from another process via private APIs; re-applying is cheap
    /// and idempotent.
    private func applyProtection(_ panel: NSPanel) {
        // Window level — currently `.statusBar` (25) so we blend in
        // with menu-bar utilities.
        panel.level = OverlayDefender.assertedLevel

        // INVISIBLE TO SCREEN CAPTURE — the macOS equivalent of
        // WDA_EXCLUDEFROMCAPTURE.  Without this, screen recording tools
        // (including LDB's own monitoring) would see the overlay.
        panel.sharingType = .none

        // Week 4 — panel is now INTERACTIVE (was click-through in week 2/3).
        // Users click icons in the top bar, click the Capture button, etc.
        // The dwell-hover path STILL works (DwellMonitor polls
        // NSEvent.mouseLocation globally, no window event listener needed),
        // so users get both activation modes without a toggle.
        //
        // Clicks OUTSIDE the panel area pass through to LDB beneath because
        // no window covers those pixels.
        panel.ignoresMouseEvents = false

        // Week 5: enable drag-from-any-background so the user can grab the
        // overlay from any non-button area to move it.  SwiftUI Buttons
        // intercept their own clicks before the drag is initiated, so
        // clicking icons / capture / pill still acts as expected — only
        // empty backdrop pixels become drag handles.
        panel.isMovableByWindowBackground = true
        panel.isMovable = true

        // Survive every Space transition LDB might trigger.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }

    /// Apply the current TransparencyMode to both overlay windows.
    /// `alphaValue` affects rendering but NOT sharingType — even at alpha 1.0
    /// the windows remain invisible to screen capture.
    func applyTransparency(_ mode: TransparencyMode) {
        model.transparencyMode = mode
        panelWindow?.alphaValue  = CGFloat(mode.alpha)
        bubbleWindow?.alphaValue = CGFloat(mode.alpha)
    }

    /// Apply the current ThemeMode by flipping the panel's NSAppearance.
    /// SwiftUI's `@Environment(\.colorScheme)` follows along so views using
    /// theme-aware colors update automatically.
    func applyTheme(_ mode: ThemeMode) {
        model.themeMode = mode
        let appearance = (mode == .dark)
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
        panelWindow?.appearance  = appearance
        bubbleWindow?.appearance = appearance
    }

    /// Wire up the action closures invoked by SwiftUI buttons.  Called once
    /// from AppDelegate so views don't need to import AppDelegate.
    struct Actions {
        var onSettings:          () -> Void
        var onCycleActivation:   () -> Void
        var onScreenshot:        () -> Void
        var onToggleTheme:       () -> Void
        var onCycleTransparency: () -> Void
        var onClose:             () -> Void
        var onCaptureClicked:    () -> Void
        var onTogglePillTapped:  () -> Void
        var onPickProvider:      (Provider) -> Void
        var onBrowser:           () -> Void
        var onSettingsChangedActivation:    (ActivationMode)   -> Void
        var onSettingsChangedResponse:      (Int)              -> Void
        var onSettingsChangedTheme:         (ThemeMode)        -> Void
        var onSettingsChangedTransparency:  (TransparencyMode) -> Void
        var onSettingsChangedProvider:      (Provider)         -> Void
    }

    func wireActions(_ a: Actions) {
        model.onSettings              = a.onSettings
        model.onCycleActivation       = a.onCycleActivation
        model.onScreenshot            = a.onScreenshot
        model.onToggleTheme           = a.onToggleTheme
        model.onCycleTransparency     = a.onCycleTransparency
        model.onClose                 = a.onClose
        model.onCaptureClicked        = a.onCaptureClicked
        model.onTogglePillTapped      = a.onTogglePillTapped
        model.onPickProvider          = a.onPickProvider
        model.onBrowser               = a.onBrowser
        model.onSettingsChangedActivation   = a.onSettingsChangedActivation
        model.onSettingsChangedResponse     = a.onSettingsChangedResponse
        model.onSettingsChangedTheme        = a.onSettingsChangedTheme
        model.onSettingsChangedTransparency = a.onSettingsChangedTransparency
        model.onSettingsChangedProvider     = a.onSettingsChangedProvider
    }

    /// Expose the shared OverlayModel so the new SettingsController can
    /// bind directly to it (segmented controls auto-update the live overlay).
    var sharedModel: OverlayModel { model }

    private func positionInCorner(_ window: NSPanel, corner: Int, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let pad: CGFloat = 16

        let origin: NSPoint
        switch OverlayCorner(rawValue: corner) ?? .topRight {
        case .topRight:
            origin = NSPoint(x: visible.maxX - size.width - pad,
                             y: visible.maxY - size.height - pad)
        case .topLeft:
            origin = NSPoint(x: visible.minX + pad,
                             y: visible.maxY - size.height - pad)
        case .bottomRight:
            origin = NSPoint(x: visible.maxX - size.width - pad,
                             y: visible.minY + pad)
        case .bottomLeft:
            origin = NSPoint(x: visible.minX + pad,
                             y: visible.minY + pad)
        }
        window.setFrameOrigin(origin)
    }
}

// OverlayModel lives in OverlayModel.swift so PlaceholderView.swift can
// see it during cross-file Swift compilation.
