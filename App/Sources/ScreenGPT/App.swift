//
//  App.swift
//  ScreenGPT
//
//  Entry point. Owns the application lifecycle and wires the long-lived
//  services together:
//
//      • BrainBridge      — child Python process via JSON-over-stdio
//      • LoginController  — login NSWindow (week 3)
//      • OverlayController — the two NSPanels (panel + bubble)
//      • DwellMonitor     — 100 Hz cursor polling → button activation
//      • CaptureService   — ScreenCaptureKit screen capture
//      • HotkeyManager    — global ⌘⇧S toggle (week 3)
//      • OverlayDefender  — re-asserts level + ordering every 250 ms
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
        // CRITICAL for LDB survival: when LDB activates, it calls
        // hideOtherApplications on .regular apps but ignores .accessory
        // ones.  This is layer 1 of the LDB-survival defense; see
        // OverlayDefender for the rest.
        app.setActivationPolicy(.accessory)

        // Install death-cause diagnostics BEFORE run() so signal handlers
        // are in place from the very first executed instruction.
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
    lazy var defender: OverlayDefender = OverlayDefender(controller: overlay)

    // ── State ───────────────────────────────────────────────────────────────
    private(set) var settings = Settings()
    private(set) var authToken: String?

    private var eventTask: Task<Void, Never>?
    private var toggleHotkeyToken: UInt32 = 0

    // ── Lifecycle ───────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("starting (build \(buildVersion()))")

        // 1. Start the brain subprocess
        do {
            try brain.start()
            log("BrainBridge started: helper=\(brain.helperPath?.path ?? "?")")
        } catch {
            fatalError("Failed to start brain: \(error)")
        }

        // 2. Consume brain events forever
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.brain.events {
                await self.handleBrainEvent(event)
            }
            self.log("Brain event stream ended.")
        }

        // 3. Pre-create overlay windows (hidden until login + hotkey)
        overlay.preload()
        log("OverlayController preloaded.")

        // 3b. Start the LDB-survival defender.
        defender.start()
        log("OverlayDefender started.")

        // 4. Wire dwell → action handler
        dwell.onActivate = { [weak self] buttonID in
            self?.handleDwellActivation(buttonID)
        }
        dwell.onProgress = { [weak self] buttonID, progress in
            self?.overlay.updateHoverProgress(buttonID: buttonID, progress: progress)
        }
        // DwellMonitor stays paused until the overlay is shown — keeps
        // CPU at 0 while we're at the login screen.

        // 4b. Wire the top-bar click actions.  These mirror the dwell-mode
        //     handlers — both activation paths call the same code so user
        //     can mix-and-match click vs hover without configuration.
        overlay.wireActions(.init(
            onHome:              { [weak self] in self?.handleHome() },
            onHide:              { [weak self] in self?.handleHide() },
            onScreenshot:        { [weak self] in Task { await self?.runScan() } },
            onToggleTheme:       { [weak self] in self?.toggleTheme() },
            onCycleTransparency: { [weak self] in self?.cycleTransparency() },
            onClose:             { NSApp.terminate(nil) },
            onCaptureClicked:    { [weak self] in Task { await self?.runScan() } },
            onTogglePillTapped:  { [weak self] in
                self?.overlay.toggleProviderDropdown()
                if let frame = self?.overlay.panelFrame {
                    self?.dwell.setButtons(self?.makeButtons(for: frame) ?? [])
                }
            },
            onPickProvider:      { [weak self] p in self?.pickProvider(p) }
        ))

        // 5. Wire LoginController's submit closure to the brain.
        login.model.submit = { [weak self] email, password in
            guard let self else { return }
            self.log("login submit for \(email)")
            self.brain.send([
                "cmd":      "login",
                "email":    email,
                "password": password,
            ])
        }

        // 6. Install global toggle hotkey (⌘⇧S).  Carbon-based, invisible to
        //    NSEvent global monitors.  Works while LDB is frontmost.
        toggleHotkeyToken = hotkeys.registerToggle { [weak self] in
            self?.handleToggleHotkey()
        }
        if toggleHotkeyToken == 0 {
            log("WARN: ⌘⇧S hotkey registration failed — another app may own it")
        } else {
            log("hotkey registered: ⌘⇧S → toggle overlay")
        }

        // 7. Stealth: auto-hide on screen lock / sleep.  Mirrors CloakGPT.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleScreenLock),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleScreenLock),
            name: NSWorkspace.willPowerOffNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleScreenLock),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)

        // 8. Ask brain for initial settings snapshot.  Reply lands in
        //    handleBrainEvent via .allSettings.
        brain.send(["cmd": "get_all_settings"])

        // 9. Boot routing — env-var quick-paths kept for development.
        //    Production path is: wait for `ready`, then show login.
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
        // Otherwise: login window is shown when the brain emits `ready`.
    }

    /// Bring up the overlay panel + start the dwell monitor.  Called from
    /// PREVIEW mode, from `login_ok` in AUTO-LOGIN mode, and from the
    /// ⌘⇧S hotkey after login.
    private func startOverlaySession() {
        overlay.setPanelVisible(true)
        if settings.bubbleEnabled {
            overlay.setBubbleVisible(true)
        }
        dwell.start()
        dwell.setButtons(makeButtons(for: overlay.panelFrame))
    }

    /// ⌘⇧S handler.  Behavior depends on app state:
    ///   • Not logged in   → bring login window forward
    ///   • Logged in, hidden → show overlay
    ///   • Logged in, visible → hide overlay
    private func handleToggleHotkey() {
        log("⌘⇧S pressed")
        if authToken == nil {
            login.show()
            return
        }
        if overlay.isPanelVisible {
            overlay.setPanelVisible(false)
            overlay.setBubbleVisible(false)
            dwell.stop()
        } else {
            startOverlaySession()
        }
    }

    // ── Top-bar action handlers (called from click closures) ───────────────

    /// Cycle dark → light → dark.  Persist via brain so the next launch
    /// remembers the choice.
    private func toggleTheme() {
        let next: ThemeMode = (overlay.modelThemeMode == .dark) ? .light : .dark
        overlay.applyTheme(next)
        brain.send(["cmd": "set_setting", "key": "theme_mode", "value": next.rawValue])
        log("theme → \(next.displayName)")
    }

    /// Cycle Solid → Glass → Ghost → Solid.  Persist via brain.
    private func cycleTransparency() {
        let cur = overlay.modelTransparencyMode
        let next = TransparencyMode(rawValue: (cur.rawValue + 1) % 3) ?? .full
        overlay.applyTransparency(next)
        brain.send(["cmd": "set_setting", "key": "transparency_mode", "value": next.rawValue])
        log("transparency → \(next.displayName) (α=\(next.alpha))")
    }

    /// Home button — placeholder for the embedded web browser.  Next
    /// iteration spawns a separate NSWindow with WKWebView + tabs + persistent
    /// session.  For now we set the answer area so the user has feedback.
    private func handleHome() {
        log("home pressed (browser not yet built)")
        overlay.setAnswer("Home / Browser — coming next update.\n\n" +
                          "This will open a built-in web browser with persistent " +
                          "tabs (ChatGPT, Claude, Gemini, anything) so you can use " +
                          "your own AI accounts directly.")
    }

    /// Hide button — hides both windows, stops the dwell poll for CPU savings.
    /// ⌘⇧S brings everything back.
    private func handleHide() {
        log("hide pressed")
        overlay.setPanelVisible(false)
        overlay.setBubbleVisible(false)
        dwell.stop()
    }

    @objc private func handleScreenLock() {
        // Defense in depth — even though sharingType=.none hides us from
        // the screen-capture pipeline, an active hover progressing during
        // a lock screen would burn CPU and look suspicious in logs.
        log("screen locked / power off — hiding overlay")
        overlay.setPanelVisible(false)
        overlay.setBubbleVisible(false)
        dwell.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let source = Diagnostics.describeCurrentAppleEvent()
        log("[FATAL-QUIT] applicationShouldTerminate called — source: \(source)")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("[CLEAN-EXIT] applicationWillTerminate fired. Shutting brain down.")
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
            // Production boot: show the login window now that the brain
            // can answer auth requests.  Skip when env-var quick-paths
            // are driving the boot.
            let env = ProcessInfo.processInfo.environment
            if env["CALIB_PREVIEW"] != "1"
                && env["CALIB_EMAIL"]   == nil
                && authToken == nil {
                login.show()
            }

        case .allSettings(let snapshot):
            settings = Settings.fromBrainSnapshot(snapshot)
            overlay.setCurrentProvider(settings.aiProvider)
            // Apply persisted theme + transparency so the panel boots with
            // the user's last-used preferences.
            if let theme = ThemeMode(rawValue: settings.themeMode) {
                overlay.applyTheme(theme)
            }
            if let trans = TransparencyMode(rawValue: settings.transparencyMode) {
                overlay.applyTransparency(trans)
            }
            log("settings loaded: provider=\(settings.aiProvider.rawValue) "
                + "theme=\(settings.themeMode) trans=\(settings.transparencyMode)")

        case .settingValue(let key, _):
            // Pull the full snapshot back to stay in sync.
            brain.send(["cmd": "get_all_settings"])
            _ = key

        case .loginOK(let token):
            authToken = token
            overlay.setLoggedIn(true)
            log("logged in (token \(token.prefix(10))…)")
            login.close()
            // Bring up the overlay immediately on first successful login
            // so the user sees the panel land.  Subsequent hides are
            // controlled by ⌘⇧S / the X button.
            startOverlaySession()

        case .loginErr(let code, let msg):
            log("login failed [\(code)]: \(msg)")
            login.setError(prettyLoginError(code: code, msg: msg))

        case .scanOK(let answer, let provider, _, _):
            log("scan answer (\(provider)): \(answer.prefix(80))…")
            overlay.setAnswer(answer)
            overlay.setScanning(false)
            overlay.setStatusBanner(nil)

        case .scanErr(let msg):
            log("scan error: \(msg)")
            overlay.setAnswer("Error: \(msg)")
            overlay.setScanning(false)
            overlay.setStatusBanner(nil)

        case .scanProgress(let stage):
            log("scan progress: \(stage)")
            overlay.setStatusBanner(prettyScanStage(stage))

        case .usage(let provider, let used, let limit, let remaining):
            log("usage: \(provider) \(used)/\(limit ?? -1) (\(remaining ?? -1) left)")

        case .log(let level, let msg):
            log("brain.\(level): \(msg)")

        case .pong:
            break

        case .machineId, .loggedOut, .shutdownOk, .usageFull, .unknown:
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

        case .hide:
            // X button — hide everything, kill dwell so CPU drops to 0.
            overlay.setPanelVisible(false)
            overlay.setBubbleVisible(false)
            dwell.stop()

        case .modeMin: settings.respMode = 0; pushRespMode()
        case .modeCon: settings.respMode = 1; pushRespMode()
        case .modeDet: settings.respMode = 2; pushRespMode()

        case .context:
            settings.ctxOn.toggle()
            brain.send(["cmd": "set_setting", "key": "ctx_on", "value": settings.ctxOn])

        case .invisible:
            settings.invMode.toggle()
            brain.send(["cmd": "set_setting", "key": "inv_mode", "value": settings.invMode])

        case .bubble:
            settings.bubbleEnabled.toggle()
            brain.send(["cmd": "set_setting", "key": "bubble_enabled", "value": settings.bubbleEnabled])
            overlay.setBubbleVisible(settings.bubbleEnabled)

        case .scrollUp:    overlay.scrollAnswer(by: -40)
        case .scrollDown:  overlay.scrollAnswer(by:  40)

        case .providerPill:
            overlay.toggleProviderDropdown()
            // Re-register dwell buttons so the four provider option rects
            // become hot when the dropdown is open.
            dwell.setButtons(makeButtons(for: overlay.panelFrame))

        case .providerOpt0: pickProvider(.grok)
        case .providerOpt1: pickProvider(.openai)
        case .providerOpt2: pickProvider(.gemini)
        case .providerOpt3: pickProvider(.claude)

        case .tab:
            overlay.setPanelVisible(true)
        }
    }

    private func pickProvider(_ p: Provider) {
        settings.aiProvider = p
        brain.send(["cmd": "set_setting", "key": "ai_provider", "value": p.rawValue])
        overlay.setCurrentProvider(p)
        overlay.collapseProviderDropdown()
        // Re-register dwell buttons so the dropdown options no longer
        // accept hover hits.
        dwell.setButtons(makeButtons(for: overlay.panelFrame))
    }

    private func pushRespMode() {
        brain.send(["cmd": "set_setting", "key": "resp_mode", "value": settings.respMode])
    }

    // ── Scan flow ───────────────────────────────────────────────────────────

    private func runScan() async {
        guard authToken != nil else {
            log("scan ignored — not logged in")
            overlay.setAnswer("Please log in first.")
            return
        }
        // Clear the answer area while scanning — the status banner is the
        // single source of truth for "what's happening right now."  Two
        // copies of "Asking Grok…" (banner + answer text) ghost each other
        // when SwiftUI re-rasterises the panel.
        overlay.setScanning(true)
        overlay.setAnswer("")
        overlay.setStatusBanner("Capturing screen…")
        do {
            let b64 = try await capture.capturePNGBase64()
            brain.send([
                "cmd":      "scan",
                "image_b64": b64,
                "mode":      settings.respMode,
                "provider":  settings.aiProvider.rawValue,
                "use_context": settings.ctxOn,
            ])
        } catch {
            log("capture failed: \(error)")
            overlay.setAnswer("Screen capture failed: \(error.localizedDescription)")
            overlay.setScanning(false)
            overlay.setStatusBanner(nil)
        }
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
        // Add provider-dropdown option rects only when the dropdown is
        // expanded — otherwise the cursor reading the answer text would
        // accidentally dwell-hit those rects.
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
