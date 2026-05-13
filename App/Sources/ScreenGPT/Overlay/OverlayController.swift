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

    /// Week 5: scroll is now handled natively by the SwiftUI ScrollView in
    /// the chat history.  Kept as a no-op so old dwell handlers compile;
    /// the scroll rails were removed from the UI entirely.
    func scrollAnswer(by delta: CGFloat) {
        _ = delta
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

    /// Week 6: 720×560 — taller answer area, fits more chat headroom.
    private let panelSize  = NSSize(width: 720, height: 560)
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

        // Week 6: panel boots in click-through mode.  InteractionZoneTracker
        // flips `ignoresMouseEvents` on/off 50×/sec based on cursor position
        // so clicks pass through to LDB EXCEPT when cursor is over our
        // chrome (top bar, capture row, manual input, resize grip, browser
        // when open).
        panel.ignoresMouseEvents = true
        // Drag is handled via the wordmark zone — when cursor is in the
        // brand area, interaction is enabled, the drag gesture catches.
        // No background drag needed; clicks on chat area go through.
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

    /// Apply the current ThemeMode.  Dark/Light flip NSAppearance so
    /// SwiftUI's @Environment(.colorScheme) follows along.  Clear keeps
    /// dark appearance (so text is white) but the views detect
    /// `themeMode == .clear` and render with near-transparent backdrops.
    func applyTheme(_ mode: ThemeMode) {
        model.themeMode = mode
        let appearance: NSAppearance?
        switch mode {
        case .dark, .clear: appearance = NSAppearance(named: .darkAqua)
        case .light:        appearance = NSAppearance(named: .aqua)
        }
        panelWindow?.appearance  = appearance
        bubbleWindow?.appearance = appearance
    }

    /// Wire up the action closures invoked by SwiftUI buttons.
    struct Actions {
        var onSettings:           () -> Void
        var onCycleResponseLen:   () -> Void
        var onToggleContext:      () -> Void
        var onScreenshot:         () -> Void
        var onToggleTheme:        () -> Void
        var onCycleTransparency:  () -> Void
        var onHide:               () -> Void
        var onClose:              () -> Void
        var onCaptureClicked:     () -> Void
        var onTogglePillTapped:   () -> Void
        var onPickProvider:       (Provider) -> Void
        var onToggleBrowser:      () -> Void
        var onSubmitManualAsk:    (String) -> Void
        var onClearAttachedImage: () -> Void
        var onSettingsChangedResponse:      (Int)              -> Void
        var onSettingsChangedTheme:         (ThemeMode)        -> Void
        var onSettingsChangedTransparency:  (TransparencyMode) -> Void
        var onSettingsChangedProvider:      (Provider)         -> Void
    }

    func wireActions(_ a: Actions) {
        model.onSettings              = a.onSettings
        model.onCycleResponseLen      = a.onCycleResponseLen
        model.onToggleContext         = a.onToggleContext
        model.onScreenshot            = a.onScreenshot
        model.onToggleTheme           = a.onToggleTheme
        model.onCycleTransparency     = a.onCycleTransparency
        model.onHide                  = a.onHide
        model.onClose                 = a.onClose
        model.onCaptureClicked        = a.onCaptureClicked
        model.onTogglePillTapped      = a.onTogglePillTapped
        model.onPickProvider          = a.onPickProvider
        model.onToggleBrowser         = a.onToggleBrowser
        model.onSubmitManualAsk       = a.onSubmitManualAsk
        model.onClearAttachedImage    = a.onClearAttachedImage
        model.onSettingsChangedResponse     = a.onSettingsChangedResponse
        model.onSettingsChangedTheme        = a.onSettingsChangedTheme
        model.onSettingsChangedTransparency = a.onSettingsChangedTransparency
        model.onSettingsChangedProvider     = a.onSettingsChangedProvider
    }

    var sharedModel: OverlayModel { model }

    // MARK: - Chat / browser / context helpers

    /// Append a message to the per-session chat log.
    func appendChat(_ msg: ChatMessage) {
        model.chat.append(msg)
    }

    /// Wipe the chat history.  Called when the user switches AI provider
    /// per user spec (per-session history is provider-scoped).
    func clearChat() {
        model.chat.removeAll()
    }

    func setBrowserMode(_ on: Bool) {
        model.isBrowserMode = on
    }

    func setContextOn(_ on: Bool) {
        model.contextOn = on
    }

    func setAttachedImage(thumb: NSImage?, b64: String?) {
        model.attachedImageThumb = thumb
        model.attachedImageB64   = b64
    }

    var modelContextOn:      Bool       { model.contextOn }
    var modelIsBrowserMode:  Bool       { model.isBrowserMode }

    /// Set the click-through state.  Called by InteractionZoneTracker on
    /// every cursor-position tick.  Safe to call rapidly — internally a
    /// no-op when the value is unchanged.
    func setIgnoresMouseEvents(_ ignores: Bool) {
        // Only act when the panel exists + the value actually changes.
        guard let win = panelWindow else { return }
        if win.ignoresMouseEvents != ignores {
            win.ignoresMouseEvents = ignores
        }
    }

    /// Compute the current interactive-zone rectangles in SCREEN coords.
    /// AppDelegate hands this to InteractionZoneTracker so the tracker can
    /// hit-test cursor position against the live UI layout.
    ///
    /// Zones (panel-local):
    ///   • Top bar row              y=0..26
    ///   • Capture row              y=34..70
    ///   • Manual input bar         y=panelH-44..panelH-6
    ///   • Resize grip              y=panelH-24..panelH (bottom-right corner)
    ///   • Browser area (if on)     covers the answer area
    ///   • Provider dropdown rows (if expanded)
    func interactionZones() -> [NSRect] {
        guard let win = panelWindow, win.isVisible else { return [] }
        let f = win.frame
        let pH = f.height
        let pW = f.width

        // SwiftUI coords are top-down inside the panel; macOS NSWindow.frame
        // is bottom-up.  So "top bar y=0..26 (top-down)" is actually
        // "y=pH-26..pH (bottom-up)" relative to panel origin.

        var zones: [NSRect] = []

        // Top bar (whole row — includes brand drag area)
        zones.append(NSRect(
            x: f.origin.x,
            y: f.origin.y + pH - 26 - 10,    // +10 for vertical padding inside panel
            width: pW,
            height: 26 + 10
        ))

        // Capture row
        zones.append(NSRect(
            x: f.origin.x + 12,
            y: f.origin.y + pH - 26 - 8 - 36 - 10,
            width: pW - 24,
            height: 36
        ))

        // Manual input bar (bottom)
        zones.append(NSRect(
            x: f.origin.x + 12,
            y: f.origin.y + 6,
            width: pW - 24,
            height: 44
        ))

        // Resize grip (bottom-right, generous hit area)
        zones.append(NSRect(
            x: f.origin.x + pW - 40,
            y: f.origin.y,
            width: 40,
            height: 40
        ))

        // Browser area covers the middle band when toggle is on
        if model.isBrowserMode {
            let topY = f.origin.y + 6 + 44 + 4          // above input bar
            let botY = f.origin.y + pH - 70 - 10 - 8    // below capture row
            zones.append(NSRect(
                x: f.origin.x + 12,
                y: topY,
                width: pW - 24,
                height: botY - topY
            ))
        }

        // Provider dropdown rows (when expanded) — overlay over capture row
        if model.providerDropdownExpanded {
            zones.append(NSRect(
                x: f.origin.x + 140,
                y: f.origin.y + pH - 76 - 4 - (28 * 4) - 4,
                width: 130,
                height: 28 * 4 + 8
            ))
        }

        return zones
    }

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
