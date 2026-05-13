//
//  Settings.swift
//  ScreenGPT
//
//  Mirror of the settings schema persisted by the Python brain.  The brain
//  is the source of truth; this struct holds an in-memory snapshot the
//  Swift UI binds to.
//
//  Snake-case keys match Brain/screenai_brain.py:SETTINGS_DEFAULT exactly.
//

import Foundation

/// Bubble / panel corner (mirrors Windows OFF_CORNER byte).
enum OverlayCorner: Int, CaseIterable, Identifiable, Codable, Sendable {
    case topRight    = 0
    case topLeft     = 1
    case bottomRight = 2
    case bottomLeft  = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .topRight:    return "Top-right"
        case .topLeft:     return "Top-left"
        case .bottomRight: return "Bottom-right"
        case .bottomLeft:  return "Bottom-left"
        }
    }
}

/// Response length (mirrors Windows OFF_MODE byte).
enum ResponseMode: Int, CaseIterable, Codable, Sendable {
    case minimal = 0
    case concise = 1
    case detailed = 2

    var displayName: String {
        switch self {
        case .minimal:  return "Minimal"
        case .concise:  return "Concise"
        case .detailed: return "Detailed"
        }
    }
}

/// Text size preset for the answer panel.
enum TextSize: Int, CaseIterable, Codable, Sendable {
    case small  = 0
    case medium = 1
    case large  = 2

    var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
}

/// In-memory snapshot of user preferences.  Mutating this does NOT persist;
/// `AppDelegate` forwards every change to the brain via `set_setting`, which
/// then writes ~/Library/Application Support/ScreenGPT/settings.json.
struct Settings: Equatable, Sendable {
    var respMode:       Int       = 1     // 0 / 1 / 2 — use ResponseMode for UI
    var panelEnabled:   Bool      = true
    var bubbleEnabled:  Bool      = false
    var bubbleFollow:   Bool      = true
    var txtsz:          Int       = 1     // 0 / 1 / 2 — use TextSize for UI
    var displaySecs:    Int       = 12    // 3-60
    var corner:         Int       = 0     // 0 / 1 / 2 / 3 — use OverlayCorner
    var invMul:         Int       = 3     // 2-6
    var ctxOn:          Bool      = false
    var invMode:        Bool      = false
    var aiProvider:     Provider  = .grok
    var dismissZone:    Bool      = false

    // ── Week 4: theme + transparency ─────────────────────────────────────
    var themeMode:        Int = 0     // 0 = dark, 1 = light (ThemeMode raw)
    var transparencyMode: Int = 1     // 0 = full, 1 = medium, 2 = low (TransparencyMode raw)

    // ── Mapping from brain snapshot ────────────────────────────────────────

    static func fromBrainSnapshot(_ s: [String: Any]) -> Settings {
        var out = Settings()
        if let v = s["resp_mode"]      as? Int    { out.respMode      = v }
        if let v = s["panel_enabled"]  as? Bool   { out.panelEnabled  = v }
        if let v = s["bubble_enabled"] as? Bool   { out.bubbleEnabled = v }
        if let v = s["bubble_follow"]  as? Bool   { out.bubbleFollow  = v }
        if let v = s["txtsz"]          as? Int    { out.txtsz         = v }
        if let v = s["display_secs"]   as? Int    { out.displaySecs   = v }
        if let v = s["corner"]         as? Int    { out.corner        = v }
        if let v = s["inv_mul"]        as? Int    { out.invMul        = v }
        if let v = s["ctx_on"]         as? Bool   { out.ctxOn         = v }
        if let v = s["inv_mode"]       as? Bool   { out.invMode       = v }
        if let v = s["ai_provider"]    as? String,
           let p = Provider(rawValue: v)          { out.aiProvider    = p }
        if let v = s["dismiss_zone"]   as? Bool   { out.dismissZone   = v }
        if let v = s["theme_mode"]        as? Int { out.themeMode        = v }
        if let v = s["transparency_mode"] as? Int { out.transparencyMode = v }
        return out
    }
}
