//
//  App.swift
//  ScreenGPT
//
//  Entry point + AppDelegate.  Owns lifecycle and wires the long-lived
//  services together.
//
//  Boot flow:
//      app launches → brain starts → ready arrives → LoginController shown
//      user signs in → login_ok → token saved → main overlay armed
//      user presses ⌘⇧S → overlay toggles visibility
//

import AppKit
import Foundation

@main
struct CalibrationApp {
    static func main() {
        let app = NSApplication.shared
        // .accessory = no Dock icon, no Cmd+Tab entry, no menu bar item.
        // CRITICAL for LDB survival.
        app.setActivationPolicy(.accessory)
        Diagnostics.install()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // ── Services ────────────────────────────────────────────────────────────
    let brain    = BrainBridge()
    let overlay  = OverlayController()
    let capture  = CaptureService()
    let login    = LoginController()
    let hotkeys  = HotkeyManager()
    let zones    = InteractionZoneTracker()
    lazy var settingsController: SettingsController = SettingsController(sharedModel: overlay.sharedModel)
    lazy var defender: OverlayDefender = OverlayDefender(controller: overlay)

    // ── State ───────────────────────────────────────────────────────────────
    private(set) var settings = Settings()
    private(set) var authToken: String?
    /// Most-recent screenshot base64 + answer — used as context when
    /// settings.ctxOn is true (sent alongside next scan/manual ask).
    private var lastScreenshotB64: String?
    private var lastAnswerText:    String?

    private var eventTask: Task<Void, Never>?
    private var toggleHotkeyToken: UInt32 = 0

    // ── Lifecycle ───────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("starting (build \(buildVersion()))")

        do {
            try brain.start()
            log("BrainBridge started: helper=\(brain.helperPath?.path ?? "?")")
        } catch {
            fatalError("Failed to start brain: \(error)")
        }

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.brain.events {
                await self.handleBrainEvent(event)
            }
            self.log("Brain event stream ended.")
        }

        overlay.preload()
        log("OverlayController preloaded.")

        defender.start()
        log("OverlayDefender started.")

        // ── Interaction zone tracker (selective click-through) ──────────────
        // The panel is click-through by default; this 50Hz poll flips
        // `ignoresMouseEvents` to false ONLY when the cursor is over one of
        // our interactive zones (top bar, capture row, manual input,
        // resize grip, browser area).  Result: clicks outside our chrome
        // pass through to LDB beneath, but our controls still work.
        zones.getZones = { [weak self] in
            self?.overlay.interactionZones() ?? []
        }
        zones.setIgnoresMouseEvents = { [weak self] ignores in
            self?.overlay.setIgnoresMouseEvents(ignores)
        }

        // ── SwiftUI click closures ──────────────────────────────────────────
        overlay.wireActions(.init(
            onSettings:           { [weak self] in self?.settingsController.show() },
            onCycleResponseLen:   { [weak self] in self?.cycleResponseLength() },
            onToggleContext:      { [weak self] in self?.toggleContext() },
            onScreenshot:         { [weak self] in Task { await self?.handleTopBarScreenshot() } },
            onToggleTheme:        { [weak self] in self?.cycleTheme() },
            onCycleTransparency:  { [weak self] in self?.cycleTransparency() },
            onHide:               { [weak self] in self?.handleHide() },
            onClose:              { NSApp.terminate(nil) },
            onCaptureClicked:     { [weak self] in Task { await self?.runScan() } },
            onTogglePillTapped:   { [weak self] in self?.overlay.toggleProviderDropdown() },
            onPickProvider:       { [weak self] p in self?.pickProvider(p) },
            onToggleBrowser:      { [weak self] in self?.toggleBrowserMode() },
            onSubmitManualAsk:    { [weak self] text in Task { await self?.runManualAsk(text) } },
            onClearAttachedImage: { [weak self] in
                self?.overlay.setAttachedImage(thumb: nil, b64: nil)
            },
            onSettingsChangedResponse:     { [weak self] r in self?.applyResponseMode(r) },
            onSettingsChangedTheme:        { [weak self] t in self?.applyTheme(t) },
            onSettingsChangedTransparency: { [weak self] t in self?.applyTransparency(t) },
            onSettingsChangedProvider:     { [weak self] p in self?.pickProvider(p) }
        ))

        // ── LoginController submit ──────────────────────────────────────────
        login.model.submit = { [weak self] email, password in
            guard let self else { return }
            self.log("login submit for \(email)")
            self.brain.send([
                "cmd":      "login",
                "email":    email,
                "password": password,
            ])
        }

        // ── Global hotkey ⌘⇧S ───────────────────────────────────────────────
        toggleHotkeyToken = hotkeys.registerToggle { [weak self] in
            self?.handleToggleHotkey()
        }
        if toggleHotkeyToken == 0 {
            log("WARN: ⌘⇧S hotkey registration failed — another app may own it")
        } else {
            log("hotkey registered: ⌘⇧S → toggle overlay")
        }

        // ── Stealth auto-hide on screen lock / sleep / power-off ────────────
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleScreenLock),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleScreenLock),
            name: NSWorkspace.willPowerOffNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleScreenLock),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)

        // ── Brain: initial settings + boot routing ──────────────────────────
        brain.send(["cmd": "get_all_settings"])

        let env = ProcessInfo.processInfo.environment
        if env["CALIB_PREVIEW"] == "1" {
            log("PREVIEW MODE — skipping login, showing overlay")
            authToken = "preview"
            overlay.setLoggedIn(true)
            startOverlaySession()
        } else if let email = env["CALIB_EMAIL"],
                  let pw    = env["CALIB_PASSWORD"],
                  !email.isEmpty, !pw.isEmpty {
            log("AUTO-LOGIN MODE — sending login for \(email)")
            brain.send([
                "cmd":      "login",
                "email":    email,
                "password": pw,
            ])
        }
        // Otherwise: login window shown when brain emits `ready`.
    }

    /// Bring up the overlay + start the cursor-zone tracker.
    private func startOverlaySession() {
        overlay.setPanelVisible(true)
        if settings.bubbleEnabled {
            overlay.setBubbleVisible(true)
        }
        zones.start()
    }

    private func handleHide() {
        log("Hide button clicked")
        overlay.setPanelVisible(false)
        overlay.setBubbleVisible(false)
        zones.stop()
    }

    private func handleToggleHotkey() {
        log("⌘⇧S pressed")
        if authToken == nil {
            login.show()
            return
        }
        if overlay.isPanelVisible {
            handleHide()
        } else {
            startOverlaySession()
        }
    }

    // ── Top-bar action handlers ─────────────────────────────────────────────

    /// Cycle Dark → Light → Clear → Dark.
    private func cycleTheme() {
        let cur = overlay.modelThemeMode
        let next = ThemeMode(rawValue: (cur.rawValue + 1) % 3) ?? .dark
        applyTheme(next)
    }

    private func cycleTransparency() {
        let cur = overlay.modelTransparencyMode
        let next = TransparencyMode(rawValue: (cur.rawValue + 1) % 3) ?? .full
        applyTransparency(next)
    }

    /// Cycle Minimal → Short → Paragraphs → Minimal.  Replaces the old
    /// activation-mode cycler in the top bar.
    private func cycleResponseLength() {
        let cur = overlay.modelResponseMode
        let next = (cur + 1) % 3
        applyResponseMode(next)
    }

    private func toggleContext() {
        let next = !overlay.modelContextOn
        overlay.setContextOn(next)
        settings.ctxOn = next
        brain.send(["cmd": "set_setting", "key": "ctx_on", "value": next])
        log("context → \(next ? "on" : "off")")
    }

    /// Top-bar camera icon — captures the screen and:
    ///   1. Copies the image to NSPasteboard so the user can ⌘V-paste it into
    ///      external apps (Google, ChatGPT, etc).
    ///   2. Attaches the image to the manual-input bar so the next Enter-press
    ///      sends it with their typed question.
    private func handleTopBarScreenshot() async {
        do {
            let b64 = try await capture.capturePNGBase64()
            guard let pngData = Data(base64Encoded: b64),
                  let image   = NSImage(data: pngData) else { return }

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(pngData, forType: .png)
            if let tiff = image.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
            overlay.setAttachedImage(thumb: image, b64: b64)
            log("screenshot copied to clipboard + attached to chat")
        } catch {
            log("screenshot failed: \(error)")
        }
    }

    private func toggleBrowserMode() {
        let next = !overlay.modelIsBrowserMode
        overlay.setBrowserMode(next)
        if next {
            BrowserController.shared.loadHomeIfBlank()
        }
        log("browser mode → \(next)")
    }

    // ── Apply-and-persist helpers ──────────────────────────────────────────

    private func applyTheme(_ mode: ThemeMode) {
        overlay.applyTheme(mode)
        settings.themeMode = mode.rawValue
        brain.send(["cmd": "set_setting", "key": "theme_mode", "value": mode.rawValue])
        log("theme → \(mode.displayName)")
    }

    private func applyTransparency(_ mode: TransparencyMode) {
        overlay.applyTransparency(mode)
        settings.transparencyMode = mode.rawValue
        brain.send(["cmd": "set_setting", "key": "transparency_mode", "value": mode.rawValue])
        log("transparency → \(mode.displayName)")
    }

    private func applyResponseMode(_ raw: Int) {
        let clamped = max(0, min(2, raw))
        overlay.setResponseMode(clamped)
        settings.respMode = clamped
        brain.send(["cmd": "set_setting", "key": "resp_mode", "value": clamped])
        log("response length → \(clamped)")
    }

    @objc private func handleScreenLock() {
        log("screen locked / power off — hiding overlay")
        overlay.setPanelVisible(false)
        overlay.setBubbleVisible(false)
        zones.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let source = Diagnostics.describeCurrentAppleEvent()
        log("[FATAL-QUIT] applicationShouldTerminate called — source: \(source)")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("[CLEAN-EXIT] applicationWillTerminate fired.")
        if toggleHotkeyToken != 0 {
            hotkeys.unregister(toggleHotkeyToken)
        }
        eventTask?.cancel()
        brain.shutdown()
        Thread.sleep(forTimeInterval: 0.05)
    }

    // ── Brain event routing ─────────────────────────────────────────────────

    private func handleBrainEvent(_ event: BrainEvent) async {
        switch event {

        case .ready(let v):
            log("brain ready (v\(v))")
            let env = ProcessInfo.processInfo.environment
            if env["CALIB_PREVIEW"] != "1"
                && env["CALIB_EMAIL"]   == nil
                && authToken == nil {
                login.show()
            }

        case .allSettings(let snapshot):
            settings = Settings.fromBrainSnapshot(snapshot)
            overlay.setCurrentProvider(settings.aiProvider)
            overlay.setResponseMode(settings.respMode)
            overlay.setContextOn(settings.ctxOn)
            if let theme = ThemeMode(rawValue: settings.themeMode) {
                overlay.applyTheme(theme)
            }
            if let trans = TransparencyMode(rawValue: settings.transparencyMode) {
                overlay.applyTransparency(trans)
            }
            // Activation mode is forced to .click in week 6 — hover is gone.
            overlay.setActivationMode(.click)
            log("settings loaded: provider=\(settings.aiProvider.rawValue) "
                + "ctx=\(settings.ctxOn) theme=\(settings.themeMode) "
                + "resp=\(settings.respMode)")

        case .settingValue(_, _):
            brain.send(["cmd": "get_all_settings"])

        case .loginOK(let token):
            authToken = token
            overlay.setLoggedIn(true)
            log("logged in (token \(token.prefix(10))…)")
            login.close()
            startOverlaySession()

        case .loginErr(let code, let msg):
            log("login failed [\(code)]: \(msg)")
            login.setError(prettyLoginError(code: code, msg: msg))

        case .scanOK(let answer, let provider, _, _):
            log("scan answer (\(provider)): \(answer.prefix(80))…")
            overlay.appendChat(.assistant(answer))
            overlay.setScanning(false)
            overlay.setStatusBanner(nil)
            lastAnswerText = answer

        case .scanErr(let msg):
            log("scan error: \(msg)")
            overlay.appendChat(.system("Error: \(msg)"))
            overlay.setScanning(false)
            overlay.setStatusBanner(nil)

        case .scanProgress(let stage):
            log("scan progress: \(stage)")
            overlay.setStatusBanner(prettyScanStage(stage))

        case .usage(let provider, let used, let limit, let remaining):
            log("usage: \(provider) \(used)/\(limit ?? -1) (\(remaining ?? -1) left)")

        case .log(let level, let msg):
            log("brain.\(level): \(msg)")

        case .pong, .machineId, .loggedOut, .shutdownOk, .usageFull, .unknown:
            break
        }
    }

    private func prettyLoginError(code: String, msg: String) -> String {
        switch code {
        case "device_limit": return "This account is already on too many devices."
        case "bad_creds":    return "Email or password is incorrect."
        case "no_plan":      return "No active subscription on this account."
        case "network":      return "Network error — check your connection."
        default:             return msg.isEmpty ? "Login failed." : msg
        }
    }

    private func prettyScanStage(_ stage: String) -> String {
        switch stage {
        case "uploading": return "Sending screenshot…"
        case "waiting":   return "Asking \(settings.aiProvider.displayName)…"
        case "parsing":   return "Parsing response…"
        default:          return stage
        }
    }

    private func pickProvider(_ p: Provider) {
        settings.aiProvider = p
        brain.send(["cmd": "set_setting", "key": "ai_provider", "value": p.rawValue])
        overlay.setCurrentProvider(p)
        overlay.collapseProviderDropdown()
        // Per-session history is provider-scoped — wipe on switch.
        overlay.clearChat()
        lastScreenshotB64 = nil
        lastAnswerText    = nil
        log("provider → \(p.rawValue) (chat cleared)")
    }

    // ── Scan flow ───────────────────────────────────────────────────────────

    private func runScan() async {
        guard authToken != nil else {
            log("scan ignored — not logged in")
            overlay.appendChat(.system("Please log in first."))
            return
        }
        overlay.setScanning(true)
        overlay.setStatusBanner("Capturing screen…")
        do {
            let b64 = try await capture.capturePNGBase64()
            // Append the user-side message to the chat so the history shows
            // "user: [screenshot]" → AI answer once it arrives.
            overlay.appendChat(.user("[screenshot]", hasImage: true))

            // The brain auto-tracks the last screenshot + answer on its
            // side and re-includes them in the next request when
            // use_context is true — Swift doesn't need to forward them.
            brain.send([
                "cmd":         "scan",
                "image_b64":   b64,
                "mode":        settings.respMode,
                "provider":    settings.aiProvider.rawValue,
                "use_context": settings.ctxOn,
            ])
            lastScreenshotB64 = b64
        } catch {
            log("capture failed: \(error)")
            overlay.appendChat(.system("Screen capture failed: \(error.localizedDescription)"))
            overlay.setScanning(false)
            overlay.setStatusBanner(nil)
        }
    }

    /// Manual text-ask flow.  Mirror of runScan but the user provides text,
    /// and we capture the current screen as supporting context (auto-context
    /// per user spec — better answers than text-only).  If they already
    /// attached an image via the Camera icon, we use that instead of
    /// capturing fresh.
    private func runManualAsk(_ text: String) async {
        guard authToken != nil else {
            overlay.appendChat(.system("Please log in first."))
            return
        }
        overlay.setScanning(true)
        overlay.setStatusBanner("Asking \(settings.aiProvider.displayName)…")

        // Decide on the image to send (attached → use it; else → capture fresh).
        let imageB64: String
        if let attached = overlay.sharedModel.attachedImageB64 {
            imageB64 = attached
            overlay.setAttachedImage(thumb: nil, b64: nil)
        } else {
            do {
                imageB64 = try await capture.capturePNGBase64()
            } catch {
                log("manual-ask capture failed: \(error)")
                overlay.appendChat(.user(text))
                overlay.appendChat(.system("Couldn't capture screen for context: \(error.localizedDescription)"))
                overlay.setScanning(false)
                overlay.setStatusBanner(nil)
                return
            }
        }
        overlay.appendChat(.user(text, hasImage: true))

        brain.send([
            "cmd":           "scan",
            "image_b64":     imageB64,
            "mode":          settings.respMode,
            "provider":      settings.aiProvider.rawValue,
            "use_context":   settings.ctxOn,
            "user_question": text,   // brain forwards to backend
        ])
        lastScreenshotB64 = imageB64
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private func buildVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func log(_ msg: String) {
        Log.write(msg)
    }
}
