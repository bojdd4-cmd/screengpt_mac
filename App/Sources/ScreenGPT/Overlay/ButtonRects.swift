//
//  ButtonRects.swift
//  ScreenGPT
//
//  Dwell hit-test rectangles for the overlay panel.  Panel-local coords,
//  bottom-up (macOS native).  Week 5: pared down to just the two dwell
//  targets that survived the chat-history redesign — the Capture button
//  and the Provider pill in the capture row.  Manual scroll rails are gone
//  (SwiftUI ScrollView handles scrolling); top-bar icons are click-only.
//

import AppKit

enum ButtonID: Int, Hashable, Sendable {
    case hide          = 0
    case modeMin       = 1
    case modeCon       = 2
    case modeDet       = 3
    case capture       = 4
    case tab           = 5
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

    /// Default panel size — week 5 bumped this from 480×320 to 720×480 so
    /// the chat history + manual input + bigger browser viewport fit.
    /// User can resize via the bottom-right grip after launch; dwell rects
    /// won't track the resize (hover users should keep the default size).
    static let panelW: CGFloat = 720
    static let panelH: CGFloat = 480

    static let tabW: CGFloat = 18
    static let tabH: CGFloat = 40

    /// Capture row hit-rects.  Layout matches the SwiftUI captureRow:
    ///     [Capture 120 px] [Pill 130 px] [Web 130 px]
    /// at x=12, y=34, with 8 px spacing.  Web is click-only — no dwell rect.
    static let allButtons: [(ButtonID, NSRect)] = [
        (.capture,       fromTopDown(x: 12,  y: 34, w: 120, h: 36)),
        (.providerPill,  fromTopDown(x: 140, y: 34, w: 130, h: 36)),
    ]

    /// Provider dropdown options.  Coordinates follow the SwiftUI dropdown
    /// offset (x=140, y=76 from panel top, 4 px padding inside the
    /// dropdown frame, 28 px row pitch).
    static let providerOptions: [(ButtonID, NSRect)] = [
        (.providerOpt0,  fromTopDown(x: 144, y: 80,  w: 122, h: 26)),
        (.providerOpt1,  fromTopDown(x: 144, y: 108, w: 122, h: 26)),
        (.providerOpt2,  fromTopDown(x: 144, y: 136, w: 122, h: 26)),
        (.providerOpt3,  fromTopDown(x: 144, y: 164, w: 122, h: 26)),
    ]

    static let tabRect: NSRect = NSRect(
        x: panelW - tabW, y: panelH - tabH, width: tabW, height: tabH
    )

    /// Top-down (origin at top-left) → bottom-up (origin at bottom-left).
    private static func fromTopDown(x: CGFloat, y: CGFloat,
                                    w: CGFloat, h: CGFloat) -> NSRect {
        NSRect(x: x, y: panelH - y - h, width: w, height: h)
    }
}
