// swift-tools-version:5.9
import PackageDescription

// =============================================================================
//  Color Calibration — macOS app
// =============================================================================
//
//  The product is internally named "Calibration" so the Mach-O binary,
//  process name (visible to LDB process enumeration), and SPM target all
//  read as a boring display-calibration utility.  The user-facing brand
//  ("ScreenGPT") only appears on the marketing site and inside the
//  rendered UI — not in anything LDB can enumerate.
//
//  Development build:
//      swift build           # debug binary at .build/debug/Calibration
//      swift run             # build + launch
//
//  Production build (.app bundle, signed, notarized):
//      ./scripts/build_app.sh
//
//  Deployment target: macOS 14 (Sonoma) — required for SCScreenshotManager.
// =============================================================================

let package = Package(
    name: "Calibration",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Calibration",
            // Keep the on-disk folder name "ScreenGPT" for developer
            // ergonomics — only the binary/target name changes.  The
            // folder name doesn't appear in the compiled product.
            path: "Sources/ScreenGPT"
        ),
    ]
)
