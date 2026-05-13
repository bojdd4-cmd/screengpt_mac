# ColorCalibration / ScreenGPT — End-to-End Mac Install & Test

This is the actual ship-able workflow.  It uses the **`com.apple.*` bundle-ID
disguise + ad-hoc signing + TCC auto-grant** technique we decoded from
CloakGPT's installer.  No dylib injection.  No LDB modification.  Just a
disguised app that LDB's process scan walks past and that has been pre-granted
Screen Recording / Accessibility / Input Monitoring permissions so it can
overlay during exams without prompting.

---

## Prerequisites

Run on a Mac with:

- **macOS 14 (Sonoma) or later** — Apple Silicon or Intel
- **SIP disabled** (Recovery Mode → `csrutil disable`)
- **AMFI disabled** (`sudo nvram boot-args="amfi_get_out_of_my_way=1"` from normal desktop, then reboot)
- **Permissive Security** on Apple Silicon (Recovery Mode → Startup Security Utility — usually a one-time setting)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Python 3.11+** — `python3 --version`
- **LockDown Browser for Mac** — installed and able to launch a practice exam

Confirm SIP + AMFI:

```bash
csrutil status                 # should say: disabled
nvram -p | grep amfi           # should show: boot-args  amfi_get_out_of_my_way=1
```

If either is missing, fix it before continuing (see CloakGPT's setup docs or
[the project-level README](./README.md) for the exact Recovery-Mode steps).

---

## 1. Build the app (on your dev Mac)

```bash
cd ~/Downloads/screengpt_mac

# Build the Python brain → Nuitka native binary
cd Brain && ./build_brain_mac.sh && cd ..

# Build the .app bundle + the distribution folder
cd App && ./scripts/build_app.sh
```

Outputs:

```
App/build/ColorCalibration.app                  ← assembled app bundle (for dev)
App/build/dist/ColorCalibration/                ← shareable user-facing folder:
    ├── ColorCalibration.app
    ├── Install.command
    └── Uninstall.command
```

Verify the bundle ID came out right:

```bash
defaults read App/build/ColorCalibration.app/Contents/Info.plist CFBundleIdentifier
# Should print: com.apple.ColorCalibration
```

And that it's universal (both arches):

```bash
lipo -archs App/build/ColorCalibration.app/Contents/MacOS/ColorCalibration
# Should print: x86_64 arm64
```

---

## 2. Install on the test Mac

Copy `App/build/dist/ColorCalibration/` to your Desktop, then:

```bash
cd ~/Desktop/ColorCalibration
chmod +x Install.command Uninstall.command
./Install.command
```

The installer:

1. Asks for your admin password (one prompt)
2. Verifies SIP + AMFI are off — refuses to continue otherwise
3. Cleans any previous install
4. Moves `ColorCalibration.app` → `/Applications/Utilities/`
5. Ad-hoc re-signs the deployed bundle
6. Writes TCC.db rows so macOS pre-grants Screen Recording / Accessibility / Input Monitoring / Microphone
7. Writes `ScreenCaptureApprovals.plist` so macOS 15+ `replayd` also pre-consents

Look for the `INSTALLATION COMPLETE` banner at the end.  All TCC permissions
should show `[OK] ... granted`.

---

## 3. Verify the install

```bash
# Bundle is where it should be
ls -la /Applications/Utilities/ColorCalibration.app

# Bundle ID is the disguised com.apple.* one
defaults read /Applications/Utilities/ColorCalibration.app/Contents/Info.plist CFBundleIdentifier

# TCC permissions are granted (auth_value = 2 means allowed)
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, auth_value FROM access WHERE client='com.apple.ColorCalibration';"
```

You should see four rows: `kTCCServiceAccessibility`, `kTCCServiceScreenCapture`,
`kTCCServiceListenEvent`, `kTCCServiceMicrophone` — all `auth_value=2`.

---

## 4. First-launch test (no LDB)

```bash
open /Applications/Utilities/ColorCalibration.app
```

What should happen:

- The app launches with NO permission prompts (TCC pre-granted, replayd pre-consented)
- The overlay panel appears (week-2 placeholder UI)
- No corruption / damaged / unidentified-developer dialogs
- Activity Monitor → search "ColorCalibration" → shows it running as a normal process

Open `~/Library/Logs/Color Calibration/calibration.log` to see the brain
spinning up and login prompts. (The week-2 placeholder doesn't have a full
login UI yet — for end-to-end you'll set `CALIB_EMAIL` / `CALIB_PASSWORD` env
vars; see below.)

---

## 5. The real test — LDB exam

This is the make-or-break:

1. **Quit ColorCalibration** if it's running:
   ```bash
   killall ColorCalibration 2>/dev/null
   ```

2. **Pre-launch ColorCalibration with credentials** (until week-3 SwiftUI login lands, use env-var login):
   ```bash
   CALIB_EMAIL="you@example.com" \
   CALIB_PASSWORD="your_password" \
   /Applications/Utilities/ColorCalibration.app/Contents/MacOS/ColorCalibration
   ```
   (Or run from Finder once login is built in.)

3. **Wait for the overlay to appear and confirm login succeeded** (check `~/Library/Logs/Color Calibration/calibration.log` for `logged in (token …)`).

4. **Launch LockDown Browser to a practice exam**:
   ```bash
   open "/Applications/LockDown Browser.app"
   ```

5. **Observe**:
   - ColorCalibration's overlay should remain visible on top of LDB
   - LDB's process scan should NOT kill ColorCalibration (because of the `com.apple.*` bundle ID disguise)
   - The overlay should be invisible to LDB's screen-recording monitoring (because of `sharingType = .none`)

6. **Trigger a scan** — hover the "Capture" button for 1.5s.  The brain takes a screenshot of LDB's content (granted by Screen Recording permission), routes through the AI provider, and the answer appears in the overlay.

7. **Tail the log live** in a separate Terminal:
   ```bash
   tail -f ~/Library/Logs/Color\ Calibration/calibration.log
   ```

---

## 6. Success criteria

- [ ] ColorCalibration's process survives LDB's launch + exam-start (no SIGKILL)
- [ ] Overlay window stays visible to the user
- [ ] LDB does NOT show a corruption / unknown-app dialog
- [ ] A screen recording made via QuickTime does NOT capture the overlay (`sharingType=.none` works)
- [ ] Hovering Capture triggers a scan and the AI returns an answer
- [ ] No "Allow X to record this screen" prompts during the whole flow (TCC pre-grant worked)

If all six pass, **Path A is fully shipped** — ScreenGPT-Mac matches the
functionality of CloakGPT using the same architectural disguise.

---

## Uninstall

```bash
cd ~/Desktop/ColorCalibration
./Uninstall.command
```

Removes the deployed bundle, all TCC rows, the replayd consent entries,
caches, prefs, saved state, and the install fingerprint marker.  SIP and AMFI
state stay as you set them — re-enable manually if/when you want to restore
default Apple security.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Install.command` refuses with "SIP still enabled" | SIP is on | Recovery Mode → `csrutil disable` → reboot |
| `Install.command` refuses with "AMFI still enabled" | Boot-arg missing | `sudo nvram boot-args="amfi_get_out_of_my_way=1"` → reboot |
| App opens but Screen Recording prompt appears | TCC csreq blob didn't match the binary | Run Uninstall.command, run Install.command again — fresh sign + fresh csreq |
| LDB shows "ColorCalibration application appears to be corrupted" | LDB's bundle-ID whitelist may not actually skip `com.apple.ColorCalibration` | Try a different `com.apple.*` ID — set `BUNDLE_ID=com.apple.AnotherName ./scripts/build_app.sh` and re-deploy |
| LDB kills the process during the exam | Bundle-ID disguise was insufficient OR `LSUIElement` was missed | Check `defaults read /Applications/Utilities/ColorCalibration.app/Contents/Info.plist LSUIElement` returns 1 |
| Overlay appears in QuickTime screen recording | `sharingType` not set correctly on the NSPanel | Check `OverlayController.swift` `panel.sharingType = .none` line |

---

## What this configuration achieves

- **Disguised as Apple system software** via `com.apple.ColorCalibration` bundle ID → LDB's process-kill scan whitelists us.
- **Ad-hoc signed, AMFI off** → macOS accepts our claim to a `com.apple.*` bundle ID despite not being Apple-signed.
- **TCC.db direct writes** → no per-permission prompt during install.  User just opens the app and it works.
- **`ScreenCaptureApprovals.plist`** → macOS 15+ replayd consent layer also pre-granted.
- **`NSWindow.sharingType = .none`** → overlay invisible to LDB's screen-recording-based monitoring.
- **`LSUIElement = true`** → no Dock icon, no Cmd+Tab entry, no menu bar → doesn't show up in LDB's app-enumeration sweep.
- **Universal binary (arm64 + x86_64)** → runs natively on Apple Silicon AND coexists with x86_64 Rosetta-emulated LDB.

That's the entire bypass.  Six tricks, all baked into the Install.command +
the build script + the existing OverlayController code.
