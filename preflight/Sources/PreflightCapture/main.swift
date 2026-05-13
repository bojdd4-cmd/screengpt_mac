// =====================================================================
//  ScreenGPT pre-flight capture test
//  ---------------------------------------------------------------------
//  Goal: determine whether macOS LockDown Browser (or any target app)
//  excludes itself from screen capture via NSWindowSharingNone — the
//  macOS equivalent of Windows' WDA_EXCLUDEFROMCAPTURE.
//
//  If it does, ScreenCaptureKit returns black pixels for those windows
//  even with Screen Recording permission granted, and the macOS port
//  of ScreenGPT is not viable in its current architecture.
//
//  Usage:
//      swift run                  # default 5-second countdown
//      DELAY=10 swift run         # longer countdown to switch apps
//
//  Output:
//      • Console verdict (green / yellow / red)
//      • PNG saved to /tmp/screengpt-preflight-capture.png
// =====================================================================

import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

// ----- Helpers ---------------------------------------------------------

/// Sample N random pixels from `image` and return the ratio that are
/// near-black (R, G, B all < 0.05). A fully-blocked capture comes back
/// as solid #000000 so a high ratio is the smoking gun.
func sampleBlackRatio(image: CGImage, samples: Int) -> Double {
    guard let bitmap = NSBitmapImageRep(cgImage: image) as NSBitmapImageRep? else {
        return 0
    }
    var blackCount = 0
    for _ in 0..<samples {
        let x = Int.random(in: 0..<image.width)
        let y = Int.random(in: 0..<image.height)
        guard let color = bitmap.colorAt(x: x, y: y) else { continue }
        if color.redComponent   < 0.05 &&
           color.greenComponent < 0.05 &&
           color.blueComponent  < 0.05 {
            blackCount += 1
        }
    }
    return Double(blackCount) / Double(samples)
}

/// Encode a CGImage as PNG to disk.
func writePNG(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "PreflightCapture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
        )
    }
    try data.write(to: url)
}

/// Format a Double percentage with one decimal.
func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

// ----- Banner ----------------------------------------------------------

print("=========================================")
print("  ScreenGPT pre-flight capture test")
print("=========================================")
print("")
print("This test captures your screen via ScreenCaptureKit and checks")
print("whether the target app (e.g. LockDown Browser) is visible in")
print("the resulting image.")
print("")

// ----- Countdown -------------------------------------------------------

let delaySeconds = Int(ProcessInfo.processInfo.environment["DELAY"] ?? "5") ?? 5

print("👉  Switch to LockDown Browser NOW (or any app you want to test).")
print("    Make sure it's the frontmost window.")
print("")
print("Capturing in \(delaySeconds) seconds...")
for i in stride(from: delaySeconds, through: 1, by: -1) {
    print("  \(i)…")
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
print("Capturing NOW.")
print("")

// ----- Main flow -------------------------------------------------------

do {
    // 1. Discover what we're allowed to capture.
    //    This call also triggers the TCC Screen Recording prompt the
    //    very first time it's invoked from a given binary.
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true
    )

    guard let display = content.displays.first else {
        print("❌  ERROR: No displays found.")
        exit(1)
    }

    print("Display:           \(display.displayID)   \(display.width) × \(display.height) pts")
    print("Applications seen: \(content.applications.count)")
    print("Windows seen:      \(content.windows.count)")
    print("")

    // List the top apps so we can confirm LDB is in scope.
    print("Top apps in capture scope:")
    for app in content.applications.prefix(10) {
        let name   = app.applicationName.isEmpty ? "(unnamed)" : app.applicationName
        let bundle = app.bundleIdentifier.isEmpty ? "—" : app.bundleIdentifier
        print("  • \(name)   [\(bundle)]")
    }
    print("")

    // 2. Build a filter that captures the entire display, nothing excluded.
    //    (For ScreenGPT proper we'd exclude our own overlay windows here,
    //    but for this test we want maximum visibility.)
    let filter = SCContentFilter(display: display, excludingWindows: [])

    // 3. Configure the capture.  Retina-friendly resolution, BGRA, no cursor.
    let config = SCStreamConfiguration()
    config.width        = display.width  * 2
    config.height       = display.height * 2
    config.pixelFormat  = kCVPixelFormatType_32BGRA
    config.showsCursor  = false
    config.capturesAudio = false

    // 4. Take the screenshot.  SCScreenshotManager is the one-shot path
    //    introduced in macOS 14; it's the recommended modern API.
    print("Calling SCScreenshotManager.captureImage(...)")
    let image: CGImage
    if #available(macOS 14.0, *) {
        image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    } else {
        print("❌  ERROR: This test requires macOS 14.0 (Sonoma) or later.")
        print("    SCScreenshotManager is unavailable on earlier macOS.")
        exit(1)
    }

    print("✅  Capture returned: \(image.width) × \(image.height) px")
    print("")

    // 5. Save to disk so the user can inspect visually.
    let outputURL = URL(fileURLWithPath: "/tmp/screengpt-preflight-capture.png")
    try writePNG(image, to: outputURL)
    print("Saved PNG to: \(outputURL.path)")

    // 6. Quantitative analysis: sample for blackness.
    let blackRatio = sampleBlackRatio(image: image, samples: 2000)
    print("Near-black pixel ratio (2000 random samples): \(pct(blackRatio))")
    print("")

    // 7. Verdict.
    print("─────────────────────────────────────────")
    if blackRatio > 0.95 {
        print("🔴  RESULT: NEARLY ALL BLACK  (\(pct(blackRatio)))")
        print("")
        print("The target app almost certainly uses NSWindowSharingNone")
        print("to exclude itself from capture — the macOS equivalent of")
        print("WDA_EXCLUDEFROMCAPTURE on Windows.")
        print("")
        print("There is no API-level workaround: macOS enforces capture")
        print("exclusion at the WindowServer level.  The ScreenGPT macOS")
        print("port is NOT VIABLE in its current architecture.")
    } else if blackRatio > 0.40 {
        print("🟡  RESULT: PARTIALLY BLACK  (\(pct(blackRatio)))")
        print("")
        print("Some content was captured but a significant fraction is")
        print("black.  The target may exclude specific windows (overlays,")
        print("modals) but not all of them.")
        print("")
        print("→ Open the PNG and check whether the actual exam content")
        print("  is visible.  If yes, the port may still be viable.")
    } else {
        print("🟢  RESULT: CAPTURE LOOKS NORMAL  (\(pct(blackRatio)) black)")
        print("")
        print("The target app's content appears to be captured.")
        print("")
        print("→ Open the PNG and verify the exam content is fully visible:")
        print("     open \(outputURL.path)")
        print("")
        print("If the exam content is clearly visible, the ScreenGPT macOS")
        print("port is VIABLE.  Proceed to week 1 of the build plan.")
    }
    print("─────────────────────────────────────────")
    print("")
    print("Auto-opening the PNG…")
    NSWorkspace.shared.open(outputURL)

} catch {
    print("")
    print("❌  ERROR: \(error)")
    print("")
    let nsErr = error as NSError
    print("Domain: \(nsErr.domain)   Code: \(nsErr.code)")
    if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] {
        print("Underlying: \(underlying)")
    }
    print("")
    print("If the error mentions permissions, grant Screen Recording")
    print("permission to your terminal app:")
    print("")
    print("  System Settings → Privacy & Security → Screen Recording")
    print("  → enable the toggle next to Terminal (or iTerm)")
    print("")
    print("Then quit and reopen your terminal and run again:")
    print("  swift run")
    exit(1)
}
