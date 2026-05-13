//
//  OverlayModel.swift
//  ScreenGPT
//
//  Shared SwiftUI model for the overlay views.
//  Week 6: removed activation/hover, added clear theme, hide closure,
//  response-length cycler closure.
//

import SwiftUI
import AppKit

/// Dark / light / clear.  Clear keeps text + buttons readable but makes
/// backdrops nearly transparent — strongest "blends in" mode.
enum ThemeMode: Int, CaseIterable, Sendable {
    case dark  = 0
    case light = 1
    case clear = 2
    var displayName: String { ["Dark", "Light", "Clear"][rawValue] }
}

enum TransparencyMode: Int, CaseIterable, Sendable {
    case full   = 0
    case medium = 1
    case low    = 2
    var alpha: Double { [1.00, 0.85, 0.60][rawValue] }
    var displayName: String { ["Solid", "Glass", "Ghost"][rawValue] }
}

/// Kept around for settings persistence — only `.click` is actually wired
/// since hover was removed in week 6.  Future re-introduction of hover
/// can re-enable the other cases.
enum ActivationMode: Int, CaseIterable, Sendable {
    case click = 0
    case hover = 1
    case both  = 2
    var displayName: String { ["Click", "Hover", "Both"][rawValue] }
    var hoverEnabled: Bool { self != .click }
}

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    enum Role: Sendable { case user, assistant, system }
    let role: Role
    let text: String
    let hasImage: Bool
    let timestamp: Date
    static func user(_ t: String, hasImage: Bool = false) -> ChatMessage {
        .init(role: .user, text: t, hasImage: hasImage, timestamp: Date())
    }
    static func assistant(_ t: String) -> ChatMessage {
        .init(role: .assistant, text: t, hasImage: false, timestamp: Date())
    }
    static func system(_ t: String) -> ChatMessage {
        .init(role: .system, text: t, hasImage: false, timestamp: Date())
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    // ── Per-session chat ────────────────────────────────────────────────────
    @Published var chat: [ChatMessage] = []
    @Published var manualInput: String = ""
    @Published var attachedImageThumb: NSImage? = nil
    @Published var attachedImageB64: String? = nil
    @Published var isScanning: Bool = false
    @Published var statusBanner: String? = nil

    // ── Browser toggle ──────────────────────────────────────────────────────
    @Published var isBrowserMode: Bool = false

    // ── Dwell highlight (legacy — week 6 doesn't fire this) ─────────────────
    @Published var hoverButton: ButtonID? = nil
    @Published var hoverProgress: Double = 0.0

    // ── Provider dropdown ───────────────────────────────────────────────────
    @Published var providerDropdownExpanded: Bool = false
    @Published var currentProvider: Provider = .grok

    // ── Position / preferences ──────────────────────────────────────────────
    @Published var corner: Int = 0
    @Published var themeMode:        ThemeMode        = .dark
    @Published var transparencyMode: TransparencyMode = .medium
    @Published var activationMode:   ActivationMode   = .click   // hardcoded click only
    @Published var responseMode:     Int              = 1
    @Published var contextOn:        Bool             = false

    // ── Lifecycle flags ─────────────────────────────────────────────────────
    @Published var isLoggedIn: Bool = false

    // ── Action closures ─────────────────────────────────────────────────────
    var onSettings:           () -> Void = {}
    var onCycleResponseLen:   () -> Void = {}    // NEW: replaces hover cycle
    var onToggleContext:      () -> Void = {}
    var onScreenshot:         () -> Void = {}
    var onToggleTheme:        () -> Void = {}
    var onCycleTransparency:  () -> Void = {}
    var onHide:               () -> Void = {}    // NEW: separate from quit
    var onClose:              () -> Void = {}
    var onCaptureClicked:     () -> Void = {}
    var onTogglePillTapped:   () -> Void = {}
    var onPickProvider:       (Provider) -> Void = { _ in }
    var onToggleBrowser:      () -> Void = {}
    var onSubmitManualAsk:    (String) -> Void = { _ in }
    var onClearAttachedImage: () -> Void = {}

    var onSettingsChangedResponse:      (Int)              -> Void = { _ in }
    var onSettingsChangedTheme:         (ThemeMode)        -> Void = { _ in }
    var onSettingsChangedTransparency:  (TransparencyMode) -> Void = { _ in }
    var onSettingsChangedProvider:      (Provider)         -> Void = { _ in }
}
