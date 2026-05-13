//
//  OverlayModel.swift
//  ScreenGPT
//
//  Shared SwiftUI model for the overlay views.  Holds all the live UI
//  state plus the action closures invoked by the SwiftUI buttons.
//
//  Week 5: added chat-history + browser-mode + manual-ask flow.
//

import SwiftUI
import AppKit

enum ThemeMode: Int, CaseIterable, Sendable {
    case dark = 0, light = 1
    var displayName: String { self == .dark ? "Dark" : "Light" }
}

enum TransparencyMode: Int, CaseIterable, Sendable {
    case full   = 0    // α 1.00
    case medium = 1    // α 0.85
    case low    = 2    // α 0.60
    var alpha: Double { [1.00, 0.85, 0.60][rawValue] }
    var displayName: String { ["Solid", "Glass", "Ghost"][rawValue] }
}

enum ActivationMode: Int, CaseIterable, Sendable {
    case click = 0
    case hover = 1
    case both  = 2

    var displayName: String { ["Click", "Hover", "Both"][rawValue] }
    var hoverEnabled: Bool { self != .click }
}

/// A single turn in the per-session chat log.  Resets on provider change
/// and on app close (not persisted to disk per user spec).
struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    enum Role: Sendable { case user, assistant, system }
    let role: Role
    let text: String
    let hasImage: Bool       // true when the user attached / captured a screenshot
    let timestamp: Date

    static func user(_ text: String, hasImage: Bool = false) -> ChatMessage {
        .init(role: .user, text: text, hasImage: hasImage, timestamp: Date())
    }
    static func assistant(_ text: String) -> ChatMessage {
        .init(role: .assistant, text: text, hasImage: false, timestamp: Date())
    }
    static func system(_ text: String) -> ChatMessage {
        .init(role: .system, text: text, hasImage: false, timestamp: Date())
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    // ── Per-session chat history ────────────────────────────────────────────
    @Published var chat: [ChatMessage] = []
    @Published var manualInput: String = ""
    @Published var attachedImageThumb: NSImage? = nil   // visible image-attached pill
    @Published var attachedImageB64: String? = nil      // sent with next manual ask
    @Published var isScanning: Bool = false
    @Published var statusBanner: String? = nil

    // ── Browser toggle (embedded WKWebView in answer area) ──────────────────
    @Published var isBrowserMode: Bool = false

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
    @Published var activationMode:   ActivationMode   = .both     // default = both
    @Published var responseMode:     Int              = 1
    @Published var contextOn:        Bool             = false

    // ── Lifecycle flags ─────────────────────────────────────────────────────
    @Published var isLoggedIn: Bool = false

    // ── Action closures ─────────────────────────────────────────────────────
    var onSettings:           () -> Void = {}
    var onCycleActivation:    () -> Void = {}
    var onScreenshot:         () -> Void = {}
    var onToggleContext:      () -> Void = {}
    var onToggleTheme:        () -> Void = {}
    var onCycleTransparency:  () -> Void = {}
    var onClose:              () -> Void = {}
    var onCaptureClicked:     () -> Void = {}
    var onTogglePillTapped:   () -> Void = {}
    var onPickProvider:       (Provider) -> Void = { _ in }
    var onToggleBrowser:      () -> Void = {}
    var onSubmitManualAsk:    (String) -> Void = { _ in }
    var onClearAttachedImage: () -> Void = {}

    var onSettingsChangedActivation:    (ActivationMode)   -> Void = { _ in }
    var onSettingsChangedResponse:      (Int)              -> Void = { _ in }
    var onSettingsChangedTheme:         (ThemeMode)        -> Void = { _ in }
    var onSettingsChangedTransparency:  (TransparencyMode) -> Void = { _ in }
    var onSettingsChangedProvider:      (Provider)         -> Void = { _ in }
}
