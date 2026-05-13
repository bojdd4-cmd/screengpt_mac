//
//  PlaceholderView.swift
//  ScreenGPT
//
//  Week 4 production overlay views.  File name kept as PlaceholderView.swift
//  to avoid a rename across SPM + git; the types inside (PlaceholderPanelView,
//  PlaceholderBubbleView) are the real production UI.
//
//  Top bar layout (6 icons, left → right):
//      [Brand (drag) ........]  [🏠 Home] [👁 Hide] [📷 Cap] [🌙/☀ Theme] [👻 Trans] [✕ Close]
//
//  • Brand wordmark on the left is a drag-by-window handle.  Clicking +
//    dragging it moves the overlay panel anywhere on screen.
//  • Each icon is a click-driven SwiftUI Button that invokes a closure
//    on OverlayModel — AppDelegate wires those closures up at startup.
//  • The Capture button below still supports hover-dwell (DwellMonitor)
//    AND click — both call the same scan handler.
//

import SwiftUI
import AppKit

// =============================================================================
//  MainPanelView (kept-name PlaceholderPanelView)
// =============================================================================

struct PlaceholderPanelView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop

            VStack(alignment: .leading, spacing: 8) {
                topBar
                captureRow
                answerArea
            }
            .padding(.vertical, 10)

            if model.providerDropdownExpanded {
                providerDropdown
            }
        }
        .frame(width: ButtonRects.panelW, height: ButtonRects.panelH)
        .ignoresSafeArea()
    }

    // MARK: - Backdrop (theme-aware)

    private var backdrop: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(panelBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(panelBorderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    private var panelBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.07, green: 0.05, blue: 0.12).opacity(0.95)
            : Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.95)
    }

    private var panelBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.12)
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.65) : .black.opacity(0.60)
    }

    private var subtleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            // Brand wordmark — DRAG HANDLE.  Wrapped in DragHandle which
            // overrides mouseDownCanMoveWindow so macOS handles the drag
            // natively (smooth, no SwiftUI gesture conflicts).
            ZStack(alignment: .leading) {
                DragHandle()
                    .allowsHitTesting(true)
                wordmark
            }
            .frame(width: 110, height: 22)
            .padding(.leading, 12)

            Spacer(minLength: 4)

            // 6-icon row, right side
            topBarIcon(symbol: "house.fill",
                       tint: .blue,
                       action: model.onHome,
                       help: "Home")

            topBarIcon(symbol: "eye.slash",
                       tint: .gray,
                       action: model.onHide,
                       help: "Hide overlay")

            topBarIcon(symbol: "camera.fill",
                       tint: .green,
                       action: { model.onScreenshot() },
                       help: "Screenshot & scan")

            topBarIcon(symbol: themeSymbol,
                       tint: themeIconTint,
                       action: model.onToggleTheme,
                       help: "Theme")

            topBarIcon(symbol: transparencySymbol,
                       tint: .purple,
                       action: model.onCycleTransparency,
                       help: "Transparency: \(model.transparencyMode.displayName)")

            topBarIcon(symbol: "xmark",
                       tint: .red,
                       action: model.onClose,
                       help: "Quit ScreenGPT")
                .padding(.trailing, 8)
        }
        .frame(height: 26)
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            ForEach(Array("ScreenGPT"), id: \.self) { ch in
                Text(String(ch))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(primaryText.opacity(0.92))
            }
        }
        .allowsHitTesting(false)   // pass through to DragHandle below
    }

    private var themeSymbol: String {
        model.themeMode == .dark ? "moon.stars.fill" : "sun.max.fill"
    }

    private var themeIconTint: Color {
        model.themeMode == .dark ? .indigo : .orange
    }

    private var transparencySymbol: String {
        switch model.transparencyMode {
        case .full:   return "circle.fill"
        case .medium: return "circle.lefthalf.filled"
        case .low:    return "circle.dotted"
        }
    }

    /// A compact click-driven top-bar icon button.  Tint hints colour, but
    /// the actual fill is subtle — bright icons would be visually noisy in
    /// a 480-wide panel.
    private func topBarIcon(symbol: String,
                            tint: Color,
                            action: @escaping () -> Void,
                            help: String) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(tint.opacity(0.45), lineWidth: 0.8)
                    )
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(primaryText)
            }
            .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Capture row

    private var captureRow: some View {
        HStack(spacing: 8) {
            captureButton
            providerPill
        }
        .padding(.horizontal, 12)
    }

    private var captureButton: some View {
        Button(action: { model.onCaptureClicked() }) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                // Hover fill — still driven by DwellMonitor for users on
                // hover-mode.  Click users see this fill briefly on press.
                if model.hoverButton == .capture {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.55))
                            .frame(width: geo.size.width * model.hoverProgress)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: model.isScanning ? "hourglass" : "viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.isScanning ? "Scanning…" : "Capture")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
            }
            .frame(width: ButtonRects.panelW - 112, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(model.isScanning)
    }

    private var providerPill: some View {
        Button(action: { model.onTogglePillTapped() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.purple.opacity(0.30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )

                if model.hoverButton == .providerPill {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.purple.opacity(0.55))
                            .frame(width: geo.size.width * model.hoverProgress)
                    }
                }

                HStack(spacing: 4) {
                    Text(model.currentProvider.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: model.providerDropdownExpanded
                          ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .frame(width: 80, height: 38)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Provider dropdown

    private var providerDropdown: some View {
        VStack(spacing: 2) {
            ForEach(Provider.allCases.indices, id: \.self) { idx in
                let p = Provider.allCases[idx]
                providerDropdownRow(provider: p)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(panelBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.50), radius: 10, x: 0, y: 4)
        )
        .frame(width: 110)
        .offset(x: ButtonRects.panelW - 124, y: 76)
    }

    private func providerDropdownRow(provider: Provider) -> some View {
        Button(action: { model.onPickProvider(provider) }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.currentProvider == provider
                          ? Color.purple.opacity(0.35)
                          : subtleFill)
                HStack {
                    Text(provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(primaryText)
                    Spacer()
                    if model.currentProvider == provider {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.purple)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 26)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Answer area

    private var answerArea: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(subtleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )

            ZStack(alignment: .topLeading) {
                Color.clear
                if let banner = model.statusBanner, model.answer.isEmpty {
                    // While the answer is empty (i.e. scan in progress) we
                    // show the status banner in-place, big and clear.
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.blue)
                            Text(banner)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(primaryText)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(model.answer)
                        .font(.system(size: 13))
                        .foregroundColor(primaryText.opacity(0.95))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .offset(y: -model.scrollOffset)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Manual scroll rail — dwell-only (hover up/down arrows)
            VStack(spacing: 4) {
                hoverableScrollArrow(id: .scrollUp,   system: "chevron.up")
                hoverableScrollArrow(id: .scrollDown, system: "chevron.down")
            }
            .padding(.trailing, 6)
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func hoverableScrollArrow(id: ButtonID, system: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(subtleFill)
            if model.hoverButton == id {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(primaryText.opacity(0.18))
                        .frame(width: geo.size.width * model.hoverProgress)
                }
            }
            Image(systemName: system)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(secondaryText)
        }
        .frame(width: 22, height: 30)
    }
}

// =============================================================================
//  BubbleView (kept-name PlaceholderBubbleView)
// =============================================================================

struct PlaceholderBubbleView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bg: Color = colorScheme == .dark
            ? Color(red: 0.07, green: 0.05, blue: 0.12).opacity(0.93)
            : Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.95)
        let border: Color = colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.12)
        let textColor: Color = colorScheme == .dark ? .white : .black

        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .overlay(
                Text(model.answer)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.leading)
                    .padding(12),
                alignment: .topLeading
            )
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
            .ignoresSafeArea()
    }
}

// =============================================================================
//  DragHandle — NSViewRepresentable that lets macOS handle window drag
//  natively from a specific subview rather than the whole window background
// =============================================================================

/// Wrap as `.overlay { DragHandle() }` or place in a ZStack — anywhere this
/// view is hit, mouseDown drag moves the parent NSWindow.  Native, smooth,
/// respects NSWindow.isMovable + isMovableByWindowBackground rules.
struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { _DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class _DragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
