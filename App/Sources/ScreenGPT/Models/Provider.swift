//
//  Provider.swift
//  ScreenGPT
//
//  The four AI providers. `rawValue` is the wire string sent in the JSON
//  protocol with the brain — matches Brain/screenai_brain.py:_PROVIDER_NAMES.
//

import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case grok
    case openai
    case gemini
    case claude

    var id: String { rawValue }

    /// User-facing brand name (shown in dropdown).
    var displayName: String {
        switch self {
        case .grok:   return "Grok"
        case .openai: return "ChatGPT"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }

    /// Specific model behind the brand (shown in tooltip / Settings).
    var modelName: String {
        switch self {
        case .grok:   return "Grok 4.1 Fast Reasoning"
        case .openai: return "GPT-4o"
        case .gemini: return "Gemini 2.5 Flash"
        case .claude: return "Claude Sonnet 4.6"
        }
    }

    /// One-line guidance shown next to the provider in Settings.
    var guidance: String {
        switch self {
        case .grok:   return "Best for multiple choice & math."
        case .openai: return "Strong general knowledge."
        case .gemini: return "Quick, good at reading text in images."
        case .claude: return "Top reasoning & long-form answers."
        }
    }

    /// Asset name for the provider's logo (lives in Assets.xcassets — added
    /// in week 3 when the SwiftUI views are wired up).
    var iconAssetName: String {
        switch self {
        case .grok:   return "grok-dark"
        case .openai: return "chatgpt"
        case .gemini: return "gemini"
        case .claude: return "claude"
        }
    }

    /// Byte value used in the legacy Windows shared-memory protocol.
    /// Not used on Mac (no shared memory), but mirrored here for consistency
    /// with Brain/screenai_brain.py:_prov_to_int / _prov_from_int.
    var byteValue: UInt8 {
        switch self {
        case .grok:   return 0
        case .openai: return 1
        case .gemini: return 2
        case .claude: return 3
        }
    }
}
