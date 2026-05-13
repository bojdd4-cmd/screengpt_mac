//
//  OverlayModel.swift
//  ScreenGPT
//
//  Shared SwiftUI model for the overlay views.  Lives in its own file so
//  PlaceholderView/MainPanelView/BubbleView and OverlayController all see
//  it during cross-file Swift compilation.
//
//  Week 3 / Week 4: extended with production-UI state (provider selection,
//  loading flag, last-error, status banner, theme, transparency) plus the
//  top-bar action closures the SwiftUI views call when their icons are
//  clicked.  AppDelegate sets the closures up at startup.
//

import SwiftUI
import AppKit

/// User-selectable theme.  Currently flips the NSPanel's NSAppearance so
/// SwiftUI's `@Environment(\.colorScheme)` follows along.
enum ThemeMode: Int, CaseIterable, Sendable {
    case dark = 0
    case light = 1

    var displayName: String {
        self == .dark ? "Dark" : "Light"
    }
}

/// Three-stop transparency cycle.  Matches CloakGPT's top-bar transparency
/// button — quick toggle between full, medium and low.  Settings panel
/// (week 5) adds a fine-grained slider on top.
enum TransparencyMode: Int, CaseIterable, Sendable {
    case full   = 0    // alpha 1.00 — opaque
    case medium = 1    // alpha 0.85 — slight see-through
    case low    = 2    // alpha 0.60 — strong see-through

    var alpha: Double {
        switch self {
        case .full:   return 1.00
        case .medium: return 0.85
        case .low:    return 0.60
        }
    }

    var displayName: String {
        switch self {
        case .full:   return "Solid"
        case .medium: return "Glass"
        case .low:    return "Ghost"
        }
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    // ── Answer area ─────────────────────────────────────────────────────────
    @Published var answer: String = "Click ScreenGPT or hover Capture to start."
    @Published var scrollOffset: CGFloat = 0
    @Published var isScanning: Bool = false
    @Published var statusBanner: String? = nil

    // ── Dwell highlight (hover mode — DwellMonitor drives this) ─────────────
    @Published var hoverButton: ButtonID? = nil
    @Published var hoverProgress: Double = 0.0

    // ── Provider dropdown ───────────────────────────────────────────────────
    @Published var providerDropdownExpanded: Bool = false
    @Published var currentProvider: Provider = .grok

    // ── Position / preferences ──────────────────────────────────────────────
    @Published var corner: Int = 0
    @Published var themeMode: ThemeMode = .dark
    @Published var transparencyMode: TransparencyMode = .medium

    // ── Lifecycle flags ─────────────────────────────────────────────────────
    @Published var isLoggedIn: Bool = false

    // ── Top-bar action closures (AppDelegate sets these at startup) ─────────
    // SwiftUI buttons call these directly so the views stay free of any
    // AppDelegate / BrainBridge dependency — easy to preview in isolation.
    var onHome:               () -> Void = {}
    var onHide:               () -> Void = {}
    var onScreenshot:         () -> Void = {}
    var onToggleTheme:        () -> Void = {}
    var onCycleTransparency:  () -> Void = {}
    var onClose:              () -> Void = {}

    // Capture button accepts both click (this) AND hover-dwell (the existing
    // DwellMonitor flow).  Both paths call into AppDelegate.runScan().
    var onCaptureClicked:     () -> Void = {}

    // Provider pill click toggles the dropdown.  Selecting a row from the
    // dropdown invokes onPickProvider(provider) — AppDelegate hands the
    // selection to the brain.
    var onTogglePillTapped:   () -> Void = {}
    var onPickProvider:       (Provider) -> Void = { _ in }
}
