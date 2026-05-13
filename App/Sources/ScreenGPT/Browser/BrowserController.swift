//
//  BrowserController.swift
//  ScreenGPT
//
//  Owns a WKWebView-backed NSWindow.  Single-tab MVP: address bar, back /
//  forward / reload, persistent cookies via WKWebsiteDataStore.default()
//  so the user can log into chat.openai.com / claude.ai / google.com and
//  the sessions persist across launches.
//
//  Stealth posture:
//    • sharingType = .none — invisible to screen capture
//    • level = .floating — sits above LDB during exams
//    • collectionBehavior = canJoinAllSpaces — survives Space transitions
//    • Window is movable from anywhere on its background.
//
//  Tab UI + bookmarks come in Phase 3.  For now the user gets one full-size
//  web view with persistent state — enough to load any AI account they have.
//

import AppKit
import WebKit
import SwiftUI

@MainActor
final class BrowserController: NSObject {

    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    private var addressField: NSTextField?

    /// URL the browser opens to on first launch (or after URL clear).
    /// "google.com" per user spec — works as a general jumping-off point.
    private static let homeURL = URL(string: "https://www.google.com/")!

    /// Lazily build the window the first time we show.
    func show() {
        let win = ensureWindow()
        if webView?.url == nil {
            webView?.load(URLRequest(url: Self.homeURL))
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }

    var isShowing: Bool { window?.isVisible ?? false }

    // MARK: - Window construction

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }

        // Build the configuration with a persistent data store — cookies +
        // localStorage survive between app launches.  Same data store macOS
        // uses for Safari's "default" website-data partition.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.customUserAgent = nil  // use system default — looks normal
        wv.navigationDelegate = self
        self.webView = wv

        // Toolbar: back / forward / reload / address bar
        let backBtn = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)!,
                               target: self, action: #selector(goBack))
        let fwdBtn  = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!,
                               target: self, action: #selector(goForward))
        let reloadBtn = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!,
                                  target: self, action: #selector(reload))
        for b in [backBtn, fwdBtn, reloadBtn] {
            b.bezelStyle = .texturedRounded
            b.translatesAutoresizingMaskIntoConstraints = false
            b.imageScaling = .scaleProportionallyDown
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let addr = NSTextField()
        addr.translatesAutoresizingMaskIntoConstraints = false
        addr.placeholderString = "Search Google or type a URL"
        addr.font = .systemFont(ofSize: 12)
        addr.bezelStyle = .roundedBezel
        addr.target = self
        addr.action = #selector(addressEntered)
        addr.heightAnchor.constraint(equalToConstant: 26).isActive = true
        self.addressField = addr

        let toolbar = NSStackView(views: [backBtn, fwdBtn, reloadBtn, addr])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.distribution = .fill
        toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)

        // Container: toolbar on top, webview below
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            wv.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Window
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Browser"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.level = .floating
        win.sharingType = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.contentView = container
        win.center()
        window = win
        return win
    }

    // MARK: - Toolbar actions

    @objc private func goBack()    { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func reload()    { webView?.reload() }

    @objc private func addressEntered() {
        guard let raw = addressField?.stringValue.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return }

        // If it looks like a domain or URL, navigate directly.  Otherwise
        // run it through Google as a search.
        let url: URL
        if raw.contains(".") && !raw.contains(" ") {
            let withScheme = raw.contains("://") ? raw : "https://\(raw)"
            url = URL(string: withScheme) ?? googleSearch(for: raw)
        } else {
            url = googleSearch(for: raw)
        }
        webView?.load(URLRequest(url: url))
    }

    private func googleSearch(for q: String) -> URL {
        let allowed = CharacterSet.urlQueryAllowed
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        return URL(string: "https://www.google.com/search?q=\(encoded)")
            ?? Self.homeURL
    }
}

// MARK: - WKNavigationDelegate (keep address bar in sync)

extension BrowserController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString
        Task { @MainActor [weak self] in
            self?.addressField?.stringValue = url ?? ""
        }
    }
}
