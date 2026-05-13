//
//  PlaceholderView.swift
//  ScreenGPT
//
//  Week 5 production overlay layout.
//
//  Top bar (6 monochrome icons, left → right):
//      [Brand wordmark — drag-handle background]
//      [⚙ Settings]   [⇄ Mode toggle]   [📷 Quick scan]
//      [🌙 Theme]     [◐ Transparency]  [✕ Close]
//
//  Capture row (3 elements, left → right):
//      [Capture (small)]   [AI dropdown]   [🌐 Browser]
//
//  Bottom-right corner has a resize grip — drag to resize the panel.
//
//  Hover-fill bars on Capture / pill / scroll rails only render when
//  `model.activationMode.hoverEnabled` is true — click-only users see a
//  cleaner UI without ghost fill animations.
//

import SwiftUI
import AppKit

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

            // Resize grip — bottom-right.  Lives in the ZStack so it stays
            // anchored even as the answer area resizes.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ResizeGrip(tint: secondaryText.opacity(0.5))
                        .frame(width: 14, height: 14)
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                }
            }
        }
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

    private var primaryText:   Color { colorScheme == .dark ? .white : .black }
    private var secondaryText: Color { colorScheme == .dark ? .white.opacity(0.65) : .black.opacity(0.60) }
    private var subtleFill:    Color { colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05) }

    /// Monochrome icon tint for top bar.  All non-destructive icons share
    /// this colour so the row blends into the panel at low transparency.
    private var iconTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.78)
    }

    // MARK: - Top bar (monochrome)

    private var topBar: some View {
        HStack(spacing: 4) {
            wordmark
                .padding(.leading, 12)

            Spacer(minLength: 4)

            topBarIcon(symbol: "gearshape.fill",
                       action: model.onSettings,
                       help: "Settings")

            topBarIcon(symbol: activationSymbol,
                       action: model.onCycleActivation,
                       help: "Activation: \(model.activationMode.displayName)")

            topBarIcon(symbol: "camera.fill",
                       action: model.onScreenshot,
                       help: "Screenshot & scan")

            topBarIcon(symbol: themeSymbol,
                       action: model.onToggleTheme,
                       help: "Theme: \(model.themeMode.displayName)")

            topBarIcon(symbol: transparencySymbol,
                       action: model.onCycleTransparency,
                       help: "Transparency: \(model.transparencyMode.displayName)")

            topBarIcon(symbol: "xmark",
                       action: model.onClose,
                       help: "Quit",
                       isDestructive: true)
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
        // No hit-testing so background drag works on this area.
        .allowsHitTesting(false)
    }

    private var activationSymbol: String {
        switch model.activationMode {
        case .click: return "cursorarrow.click.2"
        case .hover: return "hand.point.up.left.fill"
        case .both:  return "arrow.left.and.right.circle.fill"
        }
    }

    private var themeSymbol: String {
        model.themeMode == .dark ? "moon.stars.fill" : "sun.max.fill"
    }

    private var transparencySymbol: String {
        switch model.transparencyMode {
        case .full:   return "circle.fill"
        case .medium: return "circle.lefthalf.filled"
        case .low:    return "circle.dotted"
        }
    }

    /// Compact monochrome top-bar icon.  All non-destructive icons share
    /// the same tint so the bar blends at low transparency.  The X is the
    /// only outlier — subtle red for destructive-action affordance.
    private func topBarIcon(symbol: String,
                            action: @escaping () -> Void,
                            help: String,
                            isDestructive: Bool = false) -> some View {
        let tint = isDestructive ? Color.red.opacity(0.75) : iconTint
        let fill = isDestructive ? Color.red.opacity(0.10) : subtleFill
        return Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(tint.opacity(0.45), lineWidth: 0.7)
                    )
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
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
            browserButton
        }
        .padding(.horizontal, 12)
    }

    /// Downsized Capture button — was 368 wide, now 120.
    private var captureButton: some View {
        Button(action: { model.onCaptureClicked() }) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                if model.activationMode.hoverEnabled, model.hoverButton == .capture {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.55))
                            .frame(width: geo.size.width * model.hoverProgress)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: model.isScanning ? "hourglass" : "viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.isScanning ? "Scan…" : "Scan")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
            }
            .frame(width: 120, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(model.isScanning)
    }

    private var providerPill: some View {
        Button(action: { model.onTogglePillTapped() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.purple.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                if model.activationMode.hoverEnabled, model.hoverButton == .providerPill {
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
            .frame(width: 130, height: 36)
        }
        .buttonStyle(.plain)
    }

    /// New Web Browser button — sits right of the AI dropdown.  Opens the
    /// browser window managed by BrowserController.
    private var browserButton: some View {
        Button(action: { model.onBrowser() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.teal.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Web")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .frame(width: 130, height: 36)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Provider dropdown

    private var providerDropdown: some View {
        VStack(spacing: 2) {
            ForEach(Provider.allCases.indices, id: \.self) { idx in
                providerDropdownRow(provider: Provider.allCases[idx])
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
        .frame(width: 130)
        // Position the dropdown right under the AI pill in the capture row.
        // Pill is at horizontal offset 12 (padding) + 120 (capture) + 8 (spacing) = 140.
        .offset(x: 140, y: 76)
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

            // Scroll rail — hover-only (no equivalent click target).  Hidden
            // when activation mode is click-only since the user can't dwell
            // to scroll.
            if model.activationMode.hoverEnabled {
                VStack(spacing: 4) {
                    hoverableScrollArrow(id: .scrollUp,   system: "chevron.up")
                    hoverableScrollArrow(id: .scrollDown, system: "chevron.down")
                }
                .padding(.trailing, 6)
                .padding(.top, 6)
            }
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
//  Resize grip — bottom-right corner drag handle to resize the overlay
// =============================================================================

struct ResizeGrip: View {
    let tint: Color
    @State private var startFrame: NSRect?

    var body: some View {
        ZStack {
            // Diagonal hash pattern — three short lines.
            Canvas { ctx, size in
                let s = size.width
                let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round)
                for offset in [0.0, 0.35, 0.70] {
                    var path = Path()
                    path.move(to:    CGPoint(x: s,        y: s * offset))
                    path.addLine(to: CGPoint(x: s * offset, y: s))
                    ctx.stroke(path, with: .color(tint), style: stroke)
                }
            }
            Color.clear   // expand hit area
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    guard let win = currentPanelWindow() else { return }
                    if startFrame == nil { startFrame = win.frame }
                    guard let s = startFrame else { return }

                    let newW = max(360, s.width  + value.translation.width)
                    let newH = max(220, s.height + value.translation.height)
                    // Keep TOP edge fixed — origin.y moves down as height grows.
                    let topY = s.origin.y + s.height
                    let newY = topY - newH
                    win.setFrame(
                        NSRect(x: s.origin.x, y: newY, width: newW, height: newH),
                        display: true
                    )
                }
                .onEnded { _ in startFrame = nil }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    /// Walk the app's window list to find the overlay panel.  Identified by
    /// its content-view-controller type (NSHostingController<PlaceholderPanelView>).
    private func currentPanelWindow() -> NSWindow? {
        for w in NSApp.windows {
            if w.contentViewController is NSHostingController<PlaceholderPanelView> {
                return w
            }
        }
        return nil
    }
}
