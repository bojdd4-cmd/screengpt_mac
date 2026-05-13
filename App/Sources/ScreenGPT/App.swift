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
    let dwell    = DwellMonitor()
    let capture  = CaptureService()
    let login    = LoginController()
    let hotkeys  = HotkeyManager()
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

        // ── Dwell → action handler ──────────────────────────────────────────
        dwell.onActivate = { [weak self] buttonID in
            self?.handleDwellActivation(buttonID)
        }
        dwell.onProgress = { [weak self] buttonID, progress in
            self?.overlay.updateHoverProgress(buttonID: buttonID, progress: progress)
        }

        // ── SwiftUI click closures ──────────────────────────────────────────
        overlay.wireActions(.init(
            onSettings:           { [weak self] in self?.settingsController.show() },
            onCycleActivation:    { [weak self] in self?.cycleActivationMode() },
            onToggleContext:      { [weak self] in self?.toggleContext() },
            onScreenshot:         { [weak self] in Task { await self?.handleTopBarScreenshot() } },
            onToggleTheme:        { [weak self] in self?.toggleTheme() },
            onCycleTransparency:  { [weak self] in self?.cycleTransparency() },
            onClose:              { NSApp.terminate(nil) },
            onCaptureClicked:     { [weak self] in Task { await self?.runScan() } },
            onTogglePillTapped:   { [weak self] in
                self?.overlay.toggleProviderDropdown()
                if let frame = self?.overlay.panelFrame {
                    self?.dwell.setButtons(self?.makeButtons(for: frame) ?? [])
                }
            },
            onPickProvider:       { [weak self] p in self?.pickProvider(p) },
            onToggleBrowser:      { [weak self] in self?.toggleBrowserMode() },
            onSubmitManualAsk:    { [weak self] text in Task { await self?.runManualAsk(text) } },
            onClearAttachedImage: { [weak self] in
                self?.overlay.setAttachedImage(thumb: nil, b64: nil)
            },
            onSettingsChangedActivation:   { [weak self] m in self?.applyActivationMode(m) },
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

    /// Bring up the overlay + sync dwell state.
    private func startOverlaySession() {
        overlay.setPanelVisible(true)
        if settings.bubbleEnabled {
            overlay.setBubbleVisible(true)
        }
        updateDwellState()
    }

    /// Single source of truth for "should the dwell poller be running?".
    /// Call whenever panel visibility or activation mode changes.
    private func updateDwellState() {
        let shouldRun = overlay.isPanelVisible
            && overlay.modelActivationMode.hoverEnabled
        if shouldRun {
            dwell.start()
            dwell.setButtons(makeButtons(for: overlay.panelFrame))
        } else {
            dwell.stop()
        }
    }

    private func handleToggleHotkey() {
        log("⌘⇧S pressed")
        if authToken == nil {
            login.show()
            return
        }
        if overlay.isPanelVisible {
            overlay.setPanelVisible(false)
            overlay.setBubbleVisible(false)
            updateDwellState()
        } else {
            startOverlaySession()
        }
    }

    // ── Top-bar action handlers ─────────────────────────────────────────────

    private func toggleTheme() {
        let next: ThemeMode = (overlay.modelThemeMode == .dark) ? .light : .dark
        applyTheme(next)
    }

    private func cycleTransparency() {
        let cur = overlay.modelTransparencyMode
        let next = TransparencyMode(rawValue: (cur.rawValue + 1) % 3) ?? .full
        applyTransparency(next)
    }

    private func cycleActivationMode() {
        let cur = overlay.modelActivationMode
        let next = ActivationMode(rawValue: (cur.rawValue + 1) % 3) ?? .click
        applyActivationMode(next)
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

    private func applyActivationMode(_ mode: ActivationMode) {
        overlay.setActivationMode(mode)
        settings.activationMode = mode.rawValue
        brain.send(["cmd": "set_setting", "key": "activation_mode", "value": mode.rawValue])
        updateDwellState()
        log("activation → \(mode.displayName)")
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
        updateDwellState()
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
            if let act = ActivationMode(rawValue: settings.activationMode) {
                overlay.setActivationMode(act)
            }
            // Apply dwell state now that activation mode is loaded from disk.
            updateDwellState()
            log("settings loaded: provider=\(settings.aiProvider.rawValue) "
                + "act=\(settings.activationMode) ctx=\(settings.ctxOn) "
                + "theme=\(settings.themeMode) resp=\(settings.respMode)")

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

    // ── Dwell activation → behaviour ────────────────────────────────────────

    private func handleDwellActivation(_ buttonID: ButtonID) {
        log("dwell activated: \(buttonID)")
        switch buttonID {

        case .capture:
            Task { await runScan() }

        case .providerPill:
            overlay.toggleProviderDropdown()
            dwell.setButtons(makeButtons(for: overlay.panelFrame))

        case .providerOpt0: pickProvider(.grok)
        case .providerOpt1: pickProvider(.openai)
        case .providerOpt2: pickProvider(.gemini)
        case .providerOpt3: pickProvider(.claude)

        case .scrollUp:    overlay.scrollAnswer(by: -40)
        case .scrollDown:  overlay.scrollAnswer(by:  40)

        // Dead branches — old UI buttons whose rects were removed in week 5.
        // Kept for exhaustiveness; never fire because their rects aren't
        // registered with the dwell monitor.
        case .hide, .modeMin, .modeCon, .modeDet, .context,
             .invisible, .bubble, .tab:
            break
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
        dwell.setButtons(makeButtons(for: overlay.panelFrame))
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

    private func makeButtons(for panelFrame: NSRect) -> [DwellMonitor.Button] {
        var out: [DwellMonitor.Button] = []
        for (id, local) in ButtonRects.allButtons {
            let screenRect = NSRect(
                x: panelFrame.minX + local.minX,
                y: panelFrame.minY + local.minY,
                width: local.width, height: local.height
            )
            out.append(.init(id: id, rect: screenRect))
        }
        if overlay.isDropdownExpanded {
            for (id, local) in ButtonRects.providerOptions {
                let screenRect = NSRect(
                    x: panelFrame.minX + local.minX,
                    y: panelFrame.minY + local.minY,
                    width: local.width, height: local.height
                )
                out.append(.init(id: id, rect: screenRect))
            }
        }
        return out
    }

    private func buildVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func log(_ msg: String) {
        Log.write(msg)
    }
}
