//
//  CaptureService.swift
//  ScreenGPT
//
//  Single-shot screen capture via ScreenCaptureKit.  Returns the result
//  as a base64-encoded PNG ready to send to the brain as `image_b64`.
//
//  Excludes our own overlay windows from the capture (defense in depth on
//  top of `NSWindow.sharingType = .none`), so the AI never sees the panel
//  even if a future macOS version weakens window-level exclusion.
//
//  TCC prompt:  The very first call to SCShareableContent.* will trigger
//  the Screen Recording permission prompt if the user hasn't granted it
//  yet.  The Swift app's first-launch onboarding (week 3) walks the user
//  through this; for now (week 2) the prompt fires lazily on first scan.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case noMainDisplay
    case permissionDenied(underlying: Error?)
    case captureFailed(Error)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noMainDisplay:
            return "No display found."
        case .permissionDenied:
            return "Screen Recording permission required. Grant in System Settings → Privacy & Security."
        case .captureFailed(let e):
            return "Capture failed: \(e.localizedDescription)"
        case .encodingFailed:
            return "Failed to encode the screenshot."
        }
    }
}

actor CaptureService {

    /// Take a single screenshot of the main display and return base64 PNG.
    /// Our own running application is excluded so the overlay windows do
    /// not appear in the result.
    func capturePNGBase64() async throws -> String {

        // 1.  Enumerate shareable content (also triggers the TCC prompt the
        //     first time it's called from this binary).
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionDenied(underlying: error)
        }

        // 2.  Pick the main display.
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                            ?? content.displays.first else {
            throw CaptureError.noMainDisplay
        }

        // 3.  Build the exclusion list — our own bundle.  When running
        //     `swift run` outside a .app bundle, Bundle.main.bundleIdentifier
        //     is nil; in that case we don't have a way to find ourselves
        //     here, so the overlay falls back to the sharingType = .none
        //     defense.  In production (signed .app), this works as expected.
        var excluded: [SCRunningApplication] = []
        if let myBundleID = Bundle.main.bundleIdentifier {
            excluded = content.applications.filter {
                $0.bundleIdentifier == myBundleID
            }
        }

        // 4.  Build the filter + config.  Use the screen's actual pixel
        //     resolution (points × backingScaleFactor) for sharp text — the
        //     AI's OCR quality is noticeably better on Retina-resolution
        //     captures than half-resolution.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let config = SCStreamConfiguration()
        config.width  = Int(Double(display.width)  * scale)
        config.height = Int(Double(display.height) * scale)
        config.pixelFormat   = kCVPixelFormatType_32BGRA
        config.showsCursor   = false
        config.capturesAudio = false

        // 5.  Take the shot.
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }

        // 6.  Encode as PNG and return base64.  The brain decodes, crops the
        //     top chrome, resizes to 1280-wide, and re-encodes as JPEG before
        //     sending to screenai.site — we just deliver the raw pixels.
        guard let png = encodePNG(cgImage) else {
            throw CaptureError.encodingFailed
        }
        return png.base64EncodedString()
    }

    /// Same as capturePNGBase64 but returns the raw PNG Data — useful for
    /// saving a debug capture to disk during development.
    func capturePNGData() async throws -> Data {
        let b64 = try await capturePNGBase64()
        guard let data = Data(base64Encoded: b64) else {
            throw CaptureError.encodingFailed
        }
        return data
    }

    // MARK: - Encoding

    private nonisolated func encodePNG(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }
}
