//
//  BrowserController.swift
//  ScreenGPT
//
//  Lazy-built / tear-down-able WKWebView for the in-panel browser toggle.
//
//  Why lazy:
//    • WKWebView spawns a WebContent helper process.  That process is
//      highly visible to LDB's process enumeration during exams.
//    • Pre-creating it at startup leaves the helper alive even when the
//      user never opens the browser → unnecessary detection surface.
//
//  Why tear-down-able:
//    • When the user toggles browser OFF, we drop our reference to the
//      WKWebView and remove it from its superview.  AppKit + WebKit
//      then terminate the WebContent helper process within a few
//      seconds → no visible helper during the exam unless the user has
//      actively opened the browser in this session.
//    • WKWebsiteDataStore.default() keeps cookies + localStorage on
//      disk, so re-creating the WKWebView later restores logged-in
//      sessions.  Tabs / scroll position do reset.
//

import AppKit
import WebKit
import SwiftUI

@MainActor
final class BrowserController {

    static let shared = BrowserController()

    /// Live WKWebView, or nil when torn down.
    private(set) var webView: WKWebView?

    private init() { /* lazy — no webView until first .ensureWebView() */ }

    /// Return the live WKWebView, creating it (and the WebContent helper
    /// process) if needed.
    @discardableResult
    func ensureWebView() -> WKWebView {
        if let w = webView { return w }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.pageZoom = 0.80
        webView = wv
        wv.load(URLRequest(url: URL(string: "https://www.google.com/")!))
        return wv
    }

    /// Tear down the WKWebView completely so the WebContent helper
    /// process exits.  Called when the user toggles browser OFF and when
    /// LDB launches (auto-stealth).
    func teardown() {
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.removeFromSuperview()
        webView = nil
    }

    /// Called by AppDelegate when the user toggles browser ON.  A no-op
    /// if the webView already exists.  Keeps the public surface stable
    /// with the previous shape — old call sites still compile.
    func loadHomeIfBlank() {
        ensureWebView()
    }
}

// =============================================================================
//  SwiftUI wrapper — places the live WKWebView (lazy-created) into the
//  panel's view tree when browser mode is on.  Removing the wrapper from
//  the tree implicitly removes the WKWebView from its superview, which
//  combined with the AppDelegate-driven teardown() ends the helper process.
// =============================================================================

struct BrowserWebViewRepresentable: NSViewRepresentable {
    /// Lightweight placeholder shown if the WKWebView isn't live (e.g.
    /// during the gap between toggle-on and `ensureWebView()` running).
    func makeNSView(context: Context) -> NSView {
        // Return whatever WKWebView is live right now — ensureWebView()
        // is called in AppDelegate.toggleBrowserMode just before this
        // representable is created, so it'll be non-nil.
        if let wv = BrowserController.shared.webView { return wv }
        return BrowserController.shared.ensureWebView()
    }
    func updateNSView(_ nsView: NSView, context: Context) { /* nothing */ }
}
