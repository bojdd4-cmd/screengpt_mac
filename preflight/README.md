# ScreenGPT Pre-flight Capture Test

A 5-minute test that determines whether the ScreenGPT macOS port is
viable before we write a single line of the real app.

## What this tests

macOS apps can opt themselves out of screen capture by setting their
`NSWindow.sharingType` to `.none` — the macOS equivalent of Windows'
`WDA_EXCLUDEFROMCAPTURE`. If LockDown Browser for Mac does this on
its own windows, `ScreenCaptureKit` returns **black pixels** for them
even with Screen Recording permission granted, and there is no
API-level workaround. macOS enforces it at the WindowServer level.

This test captures the screen via `SCScreenshotManager`, samples the
result for blackness, and tells you green / yellow / red.

## Requirements

- macOS 14.0 (Sonoma) or later — `SCScreenshotManager` was introduced
  in macOS 14. If you need to run on macOS 12.3–13, swap to the
  `SCStream` path (a few lines in `main.swift`).
- Xcode Command Line Tools — install with `xcode-select --install`
- Screen Recording permission for your terminal — granted on first
  run (the system will prompt you).

## How to run

1. **Transfer this folder to your Mac.**
   The whole `screengpt_mac/preflight/` folder. AirDrop, USB stick,
   `git clone`, whatever you prefer.

2. **Install LockDown Browser for Mac.**
   Or whatever target app you want to test against.

3. **Open Terminal in the `preflight` folder.**
   ```
   cd ~/Downloads/screengpt_mac/preflight
   ```

4. **Build and run.**
   ```
   swift run
   ```
   First build takes ~30 s while Swift resolves dependencies.
   Subsequent runs are instant.

5. **During the 5-second countdown, switch focus to LockDown Browser.**
   Get it into the exact state you want to test — ideally a real
   exam or practice quiz with question content visible.

6. **Read the verdict.**
   The script prints one of three results and saves a PNG to
   `/tmp/screengpt-preflight-capture.png`, then auto-opens it in
   Preview.

## Interpreting the result

| Black ratio | Verdict | Meaning |
|-------------|---------|---------|
| **>95% black** | 🔴 NOT VIABLE | LDB blocks capture. The macOS port cannot proceed in its current architecture. |
| **40–95% black** | 🟡 INSPECT MANUALLY | Partial capture — open the PNG to see whether exam content is visible. May still be viable. |
| **<40% black** | 🟢 VIABLE | Capture is normal. Proceed to week 1 of the build plan. |

The auto-opened PNG is the ground truth. Even if the script says
green, **open the PNG and verify the actual exam questions are
readable** before committing to the rewrite.

## Permission troubleshooting

If you see a permission error like:

```
The user has not granted screen recording permission
```

…then:

1. Open **System Settings → Privacy & Security → Screen Recording**
2. Find your terminal app (Terminal, iTerm, etc.) and toggle it on.
   If it's not in the list, click `+`, navigate to `/Applications/Utilities/`,
   and add `Terminal.app` (or your terminal of choice).
3. **Quit and reopen the terminal completely** — TCC permission only
   takes effect on a fresh process.
4. Re-run `swift run`.

## Customizing the test

| Variable | Effect |
|----------|--------|
| `DELAY=10 swift run` | 10-second countdown instead of 5 |

To test against a different app, just change which app is frontmost
during the countdown. The script captures the whole screen, not a
specific window.

## What to do after the test

- **🟢 Green:** Proceed to week 1 of the build plan (brain extraction
  + Nuitka build + IPC protocol).
- **🟡 Yellow:** Inspect the PNG. If exam content is visible, proceed.
  If not, re-test with LDB in different states (login screen vs.
  active exam vs. answer-review).
- **🔴 Red:** The current architecture won't work on macOS. Options:
  1. Drop macOS support for now and focus on Windows.
  2. Investigate whether LDB on Mac uses a less-aggressive exclusion
     in some sub-states (e.g. before an exam starts).
  3. Pivot to a different category of tools — e.g. a typed-answer
     companion that doesn't need to see exam content, only the
     student's typed query.

## Cleanup

```
swift package clean
rm -rf .build
rm /tmp/screengpt-preflight-capture.png
```

## Files in this folder

| File | Purpose |
|------|---------|
| `Package.swift` | Swift Package manifest (deployment target macOS 14) |
| `Sources/PreflightCapture/main.swift` | The entire test logic |
| `README.md` | This file |
