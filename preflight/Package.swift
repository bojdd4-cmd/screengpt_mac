// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PreflightCapture",
    platforms: [
        // SCScreenshotManager requires macOS 14 (Sonoma).
        // If you need to test on macOS 12.3–13, swap to the SCStream path
        // marked in main.swift — leaving the fast path as the default.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PreflightCapture",
            path: "Sources/PreflightCapture"
        )
    ]
)
