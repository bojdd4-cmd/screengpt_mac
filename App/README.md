# ScreenGPT Swift App

The native macOS shell. Wraps the Python brain ([../Brain/](../Brain/)) and
provides the platform-specific layer: overlay windows, dwell-based cursor
hit-testing, screen capture, global hotkeys, login UI, settings UI.

This is week 2 of the build plan — **plumbing only**. The SwiftUI UI work,
hotkeys, and polish come in weeks 3–4.

## Directory layout

```
App/
├── Package.swift                          # Swift Package manifest (macOS 14+)
├── Sources/
│   └── ScreenGPT/
│       ├── App.swift                      # @main + AppDelegate
│       ├── BrainBridge.swift              # subprocess + JSON IPC
│       ├── BrainEvent.swift               # decoded event enum
│       ├── Models/
│       │   ├── Provider.swift             # the 4 AI providers
│       │   ├── Settings.swift             # mirror of brain's settings schema
│       │   └── Usage.swift                # token-usage snapshots
│       └── Overlay/
│           ├── OverlayController.swift    # owns the 2 NSWindows
│           ├── DwellMonitor.swift         # 100 Hz cursor polling
│           ├── CaptureService.swift       # ScreenCaptureKit wrapper
│           ├── ButtonRects.swift          # hit-test layout
│           └── PlaceholderView.swift      # week-2 SwiftUI placeholder
├── scripts/
│   └── build_app.sh                       # assemble ScreenGPT.app bundle
└── README.md                              # this file
```

## What's implemented in week 2

| Component | Status |
|-----------|--------|
| `BrainBridge` — spawn helper, JSON-over-stdio, AsyncStream events | ✅ |
| `BrainEvent` — typed decoding of every event the brain emits | ✅ |
| `Settings` / `Provider` / `Usage` — Swift mirrors of the brain's types | ✅ |
| `OverlayController` — two NSWindows, click-through, capture-excluded | ✅ |
| `DwellMonitor` — 100 Hz cursor poll, 1.5 s dwell, repeat for scrolls | ✅ |
| `CaptureService` — ScreenCaptureKit one-shot screenshot | ✅ |
| `ButtonRects` — hit-test layout matching hook.cpp | ✅ |
| `AppDelegate` — wires everything; PREVIEW mode shows overlay immediately | ✅ |
| `build_app.sh` — produces a `ScreenGPT.app` bundle with embedded brain | ✅ |

## What's deferred to weeks 3–4

| Component | When |
|-----------|------|
| Login screen (SwiftUI) | Week 3 |
| Control panel (SwiftUI) | Week 3 |
| Real main panel + bubble views (SwiftUI) | Week 3 |
| Settings window (SwiftUI) | Week 3 |
| TCC onboarding view | Week 3 |
| `HotkeyManager` (Carbon RegisterEventHotKey) | Week 4 |
| Spring animations, hover-fill polish | Week 4 |
| Simultaneous-mode wiring (both panel + bubble at once) | Week 4 |
| End-to-end exam test | Week 4 |
| Code signing + notarization | Week 5 |

## Prerequisites (on Mac)

```
# Xcode Command Line Tools
xcode-select --install

# Swift 5.9+ (ships with Xcode 15+; macOS 14 has it built in)
swift --version

# Python 3.11+ for the brain build
python3 --version
```

## Development build (fastest iteration)

The brain and the Swift binary build independently. For development you
don't need to assemble a .app bundle — `swift run` is enough, and the
SCREENGPT_HELPER_PATH env var tells the Swift binary where to find the
already-built brain.

```bash
# 1. Build the brain once (or after Python changes)
cd ../Brain
./build_brain_mac.sh
# → ../Brain/build/helper

# 2. Build + launch the Swift app
cd ../App
swift run

# Or with a custom brain path:
SCREENGPT_HELPER_PATH=/full/path/to/helper swift run

# Or to skip login + see the overlay immediately:
SCREENGPT_PREVIEW=1 swift run
```

## Production build (.app bundle)

```bash
cd App
chmod +x scripts/build_app.sh
./scripts/build_app.sh
# → build/ScreenGPT.app
```

Output is a universal binary (Apple Silicon + Intel), ~30 MB total
(Swift binary + Nuitka helper + Info.plist). The bundle is **unsigned** —
week 5 adds the code-signing + notarization pipeline.

Bundle layout produced by `build_app.sh`:

```
ScreenGPT.app/
├── Contents/
│   ├── Info.plist                       # display name: "ScreenGPT"
│   ├── PkgInfo                          # APPL????
│   ├── MacOS/
│   │   └── ColorCalibration             # ← Mach-O binary, generic name
│   └── Resources/
│       └── brain/
│           └── helper                   # ← Nuitka-built Python brain
```

The Mach-O binary inside `Contents/MacOS/` is named `ColorCalibration`
(not `ScreenGPT`) so it doesn't stand out if LDB enumerates running
processes. Activity Monitor, Finder, and the Dock all show
`CFBundleDisplayName = "ScreenGPT"`, but `ps`, `proc_listpids`, and
low-level enumeration see `ColorCalibration` — same trick the Windows
product uses.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `SCREENGPT_HELPER_PATH` | Override the helper-binary location (development) |
| `SCREENGPT_PREVIEW=1`   | Skip login, show the overlay panel immediately |

## NSWindow flags (the heart of the product on macOS)

`OverlayController.makeOverlayWindow()` sets these on BOTH overlay
windows. These three are non-negotiable — change any of them and the
product breaks:

```swift
window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
// ↑ Above fullscreen LDB.  Stays visible during exams.

window.sharingType = .none
// ↑ Invisible to screen recording.  This is the macOS equivalent of
//   Windows' WDA_EXCLUDEFROMCAPTURE — LDB's proctoring software cannot
//   see the overlay even with Screen Recording permission granted.

window.ignoresMouseEvents = true
// ↑ Click-through.  Cursor passes through to LDB underneath.  Hover
//   detection works because DwellMonitor polls NSEvent.mouseLocation
//   independently of window mouse focus.
```

The `collectionBehavior` ensures the overlay stays visible when LDB
enters full-screen mode or switches Spaces.

## Testing the brain bridge without writing UI

Use the preview mode to show the overlay immediately:

```bash
SCREENGPT_PREVIEW=1 swift run
```

You should see a translucent dark rounded-rect panel in the top-right
corner of the main screen, with a "Hover to scan" button. Hover the
cursor over the button for 1.5 s — the AppDelegate logs a `dwell
activated: capture` line and triggers a scan via the brain. Without
being logged in, the scan returns "Please log in first." in the panel.

The actual login flow is week 3.

## Troubleshooting

**`BrainBridgeError.helperNotFound`** — The Swift binary couldn't locate
the brain helper. Set `SCREENGPT_HELPER_PATH` to its absolute path:

```bash
SCREENGPT_HELPER_PATH="$(pwd)/../Brain/build/helper" swift run
```

**Screen Recording permission denied** — On first scan, macOS prompts
to grant Screen Recording. Allow it, then **quit and restart the app
completely** — TCC changes only take effect on a fresh process. (Once
the proper onboarding flow lands in week 3 this is handled gracefully.)

**Window doesn't appear with `SCREENGPT_PREVIEW=1`** — Check the console
for `OverlayController preloaded` log lines. If you see them but no
window, your screen's main display might not match `CGMainDisplayID()`
— file a note and we'll handle multi-display in week 4.
