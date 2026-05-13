//
//  ButtonRects.swift
//  ScreenGPT
//
//  Hit-test rectangles for the main overlay panel and the cursor bubble,
//  expressed in panel-local coordinates.  Mirrors hook.cpp lines 601-629
//  (Windows) and converts top-down Windows coords to macOS bottom-up.
//
//  Layout reference (looking at the panel from the user's perspective):
//
//      ┌──────────────────────────────────────────────────────────┐
//      │ [Min][Con][Det]                  [Ctx][Inv][Bub]  [Hide] │ ← header
//      │                                                          │
//      │ ┌────────────────────────────┐ ┌──────┐                 │
//      │ │   Capture                   │ │Provd │                 │
//      │ └────────────────────────────┘ └──────┘                 │
//      │ ┌──────────────────────────────────────┐                │
//      │ │                                      │  ▲             │
//      │ │   ANSWER TEXT                        │  ▼             │
//      │ │                                      │                │
//      │ └──────────────────────────────────────┘                │
//      └──────────────────────────────────────────────────────────┘
//

import AppKit

/// Identifier for every dwell-activatable button in the overlay.
/// Mirrors the integer IDs in hook.cpp:InputThread.
enum ButtonID: Int, Hashable, Sendable {
    case hide          = 0
    case modeMin       = 1
    case modeCon       = 2
    case modeDet       = 3
    case capture       = 4
    case tab           = 5   // corner-tab hover (panel hidden state)
    case context       = 6
    case scrollUp      = 7
    case scrollDown    = 8
    case invisible     = 9
    case bubble        = 10
    case providerPill  = 11
    case providerOpt0  = 12
    case providerOpt1  = 13
    case providerOpt2  = 14
    case providerOpt3  = 15
}

enum ButtonRects {

    // Panel dimensions match Windows OVL_W / OVL_H so the layout math
    // ports directly.
    static let panelW: CGFloat = 480
    static let panelH: CGFloat = 320

    static let tabW: CGFloat = 18
    static let tabH: CGFloat = 40

    /// Buttons whose RECTS still need dwell-hover hit testing.  Week 4
    /// switched the top bar to click-driven SwiftUI Buttons, so the icons
    /// up there no longer participate in dwell — clicking is the only path
    /// for Home / Hide / Screenshot / Theme / Transparency / Close.  The
    /// big Capture row and the scroll rails keep hover-dwell because users
    /// like the "hover to scan" affordance from the Windows version.
    /// Week 5 — new compact capture row.  Layout: [Capture 120] [Pill 130]
    /// [Browser 130] starting at x=12 with 8 pt gaps.  Browser button is
    /// click-only (no dwell rect).
    static let allButtons: [(ButtonID, NSRect)] = [
        (.capture,       fromTopDown(x: 12,  y: 34,  w: 120, h: 36)),
        (.providerPill,  fromTopDown(x: 140, y: 34,  w: 130, h: 36)),

        // Scroll rails inside the answer area — hover-only.
        (.scrollUp,      fromTopDown(x: panelW - 36, y: 168, w: 26, h: 60)),
        (.scrollDown,    fromTopDown(x: panelW - 36, y: 250, w: 26, h: 60)),
    ]

    /// Provider dropdown options.  Only active when the dropdown is expanded.
    /// Positions follow the SwiftUI dropdown offset (x=140, y=76 from
    /// the panel top, with 4 pt internal padding and 28 pt row pitch).
    static let providerOptions: [(ButtonID, NSRect)] = [
        (.providerOpt0,  fromTopDown(x: 144, y: 80,  w: 122, h: 26)),
        (.providerOpt1,  fromTopDown(x: 144, y: 108, w: 122, h: 26)),
        (.providerOpt2,  fromTopDown(x: 144, y: 136, w: 122, h: 26)),
        (.providerOpt3,  fromTopDown(x: 144, y: 164, w: 122, h: 26)),
    ]

    /// The collapsed-state corner tab.  Active when the panel is hidden so
    /// the user can hover the corner to bring it back.
    static let tabRect: NSRect = NSRect(
        x: panelW - tabW, y: panelH - tabH, width: tabW, height: tabH
    )

    /// Translate from Windows-style top-down coords (origin at top-left of
    /// the panel) to macOS-style bottom-up coords (origin at bottom-left).
    private static func fromTopDown(x: CGFloat, y: CGFloat,
                                    w: CGFloat, h: CGFloat) -> NSRect {
        NSRect(x: x, y: panelH - y - h, width: w, height: h)
    }
}
