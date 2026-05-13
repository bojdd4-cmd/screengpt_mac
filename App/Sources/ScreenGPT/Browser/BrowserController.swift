//
//  BrowserController.swift
//  ScreenGPT
//
//  Singleton holder for the embedded WKWebView.  Phase 3 switched from a
//  separate browser NSWindow to an in-panel toggle — the answer area
//  swaps to show this WKWebView when the user clicks the Web button.
//
//  Persistence:
//    • WKWebsiteDataStore.default() means cookies, localStorage, and
//      IndexedDB all persist between launches.  The user can log into
//      chat.openai.com / claude.ai / google.com once and stay logged in.
//    • The WKWebView instance is held statically here so toggling the
//      browser off and back on preserves the current page, scroll
//      position, and any in-page state.
//

import AppKit
import WebKit
import SwiftUI

@MainActor
final class BrowserController {

    static let shared = BrowserController()

    let webView: WKWebView

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        // Start zoomed out so pages fit naturally in the embedded viewport
        // — the WKWebView's default 1.0 magnification crops the right side
        // of most desktop sites at the panel's default width.
        wv.pageZoom = 0.80
        self.webView = wv

        loadHomeIfBlank()
    }

    /// Call from the toggle-on path to ensure a sensible landing page.
    func loadHomeIfBlank() {
        if webView.url == nil {
            webView.load(URLRequest(url: URL(string: "https://www.google.com/")!))
        }
    }

    func goBack()    { webView.goBack()    }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload()    }
    func goHome()    { webView.load(URLRequest(url: URL(string: "https://www.google.com/")!)) }

    /// Navigate to a URL or run a Google search if the input doesn't look
    /// like a URL.  Same heuristic Safari uses.
    func navigate(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let url: URL
        if trimmed.contains(".") && !trimmed.contains(" ") {
            let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            url = URL(string: withScheme) ?? googleSearch(for: trimmed)
        } else {
            url = googleSearch(for: trimmed)
        }
        webView.load(URLRequest(url: url))
    }

    private func googleSearch(for q: String) -> URL {
        let allowed = CharacterSet.urlQueryAllowed
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        return URL(string: "https://www.google.com/search?q=\(encoded)")
            ?? URL(string: "https://www.google.com/")!
    }
}

// =============================================================================
//  SwiftUI wrapper — reparents the singleton WKWebView into the SwiftUI view
//  hierarchy each time it's rendered.  Removing this wrapper from the view
//  tree implicitly removes the WKWebView from its superview but keeps the
//  WKWebView alive (held by BrowserController.shared).
// =============================================================================

struct BrowserWebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        // Same instance every time — keeps page state across browser toggles.
        BrowserController.shared.webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { /* nothing */ }
}
