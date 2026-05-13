//
//  BrowserController.swift  —  STUB (NO WEBKIT)
//  ScreenGPT
//
//  Temporary hypothesis-test build: WebKit framework linkage stripped to
//  see if LDB's mid-exam process-kill is triggered by WebKit being
//  loaded in our process.  Browser feature is disabled in this build —
//  clicking Web shows an empty placeholder.  Full browser comes back
//  later via a separate process if WebKit was indeed the trigger.
//
//  NO `import WebKit`.  Linker should not include WebKit.framework.
//

import AppKit
import SwiftUI

@MainActor
final class BrowserController {

    static let shared = BrowserController()
    private(set) var webView: NSView? = nil
    private init() {}

    @discardableResult
    func ensureWebView() -> NSView {
        if let v = webView { return v }
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 0.10, green: 0.07, blue: 0.16, alpha: 1.0).cgColor
        webView = view
        return view
    }

    func teardown() {
        webView?.removeFromSuperview()
        webView = nil
    }

    func loadHomeIfBlank() { _ = ensureWebView() }
}

// =============================================================================
//  SwiftUI wrapper — shows a placeholder NSView (no WebKit content).  When
//  the user toggles the Web button, an empty dark rectangle appears where
//  the browser would.  Real browser will return as a separate process if
//  this hypothesis test confirms WebKit was the LDB trigger.
// =============================================================================

struct BrowserWebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        BrowserController.shared.ensureWebView()
    }
    func updateNSView(_ nsView: NSView, context: Context) { /* nothing */ }
}
