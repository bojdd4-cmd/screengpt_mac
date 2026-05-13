//
//  OverlayModel.swift
//  ScreenGPT
//
//  Shared SwiftUI model for the overlay views.  Lives in its own file so
//  PlaceholderView, OverlayController, and the various smaller views all
//  see it during cross-file compilation.
//
//  Week 5: added ActivationMode + Settings/Browser action closures.
//

import SwiftUI
import AppKit

enum ThemeMode: Int, CaseIterable, Sendable {
    case dark = 0, light = 1
    var displayName: String { self == .dark ? "Dark" : "Light" }
}

enum TransparencyMode: Int, CaseIterable, Sendable {
    case full   = 0    // alpha 1.00
    case medium = 1    // alpha 0.85
    case low    = 2    // alpha 0.60

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

/// How dwell + click activation interact.  Defaults to .click (matches
/// CloakGPT's default + most Mac users' expectation).  Hover users can
/// switch to .hover (or .both) in the Settings panel.
enum ActivationMode: Int, CaseIterable, Sendable {
    case click = 0    // click only — no hover-fill, no dwell activation
    case hover = 1    // hover only — dwell-fill + 1.5s activation
    case both  = 2    // both — click OR dwell triggers; hover-fill visible

    var displayName: String {
        switch self {
        case .click: return "Click"
        case .hover: return "Hover"
        case .both:  return "Both"
        }
    }

    /// True iff dwell-hover should produce visible fill bars and fire
    /// activations.  PlaceholderView reads this to gate the fill overlay.
    var hoverEnabled: Bool { self != .click }
}

@MainActor
final class OverlayModel: ObservableObject {
    // ── Answer area ─────────────────────────────────────────────────────────
    @Published var answer: String = "Click Capture, hover Capture, or press ⌘⇧S."
    @Published var scrollOffset: CGFloat = 0
    @Published var isScanning: Bool = false
    @Published var statusBanner: String? = nil

    // ── Dwell highlight (only meaningful when activationMode.hoverEnabled) ──
    @Published var hoverButton: ButtonID? = nil
    @Published var hoverProgress: Double = 0.0

    // ── Provider dropdown ───────────────────────────────────────────────────
    @Published var providerDropdownExpanded: Bool = false
    @Published var currentProvider: Provider = .grok

    // ── Position / preferences ──────────────────────────────────────────────
    @Published var corner: Int = 0
    @Published var themeMode:        ThemeMode        = .dark
    @Published var transparencyMode: TransparencyMode = .medium
    @Published var activationMode:   ActivationMode   = .click
    @Published var responseMode:     Int              = 1     // 0=min 1=short 2=det

    // ── Lifecycle flags ─────────────────────────────────────────────────────
    @Published var isLoggedIn: Bool = false

    // ── Top-bar action closures ─────────────────────────────────────────────
    var onSettings:           () -> Void = {}
    var onCycleActivation:    () -> Void = {}
    var onScreenshot:         () -> Void = {}
    var onToggleTheme:        () -> Void = {}
    var onCycleTransparency:  () -> Void = {}
    var onClose:              () -> Void = {}

    // ── Capture row action closures ─────────────────────────────────────────
    var onCaptureClicked:     () -> Void = {}
    var onTogglePillTapped:   () -> Void = {}
    var onPickProvider:       (Provider) -> Void = { _ in }
    var onBrowser:            () -> Void = {}

    // ── Settings panel actions ──────────────────────────────────────────────
    var onSettingsChangedActivation: (ActivationMode)   -> Void = { _ in }
    var onSettingsChangedResponse:   (Int)              -> Void = { _ in }
    var onSettingsChangedTheme:      (ThemeMode)        -> Void = { _ in }
    var onSettingsChangedTransparency: (TransparencyMode) -> Void = { _ in }
    var onSettingsChangedProvider:   (Provider)         -> Void = { _ in }
}
