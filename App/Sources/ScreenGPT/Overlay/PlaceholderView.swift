//
//  PlaceholderView.swift
//  ScreenGPT
//
//  Week 5 overlay layout.
//
//  Top bar (7 monochrome icons + brand drag area):
//      [Brand]   [⚙ Settings] [⇄ Mode] [🔗 Context] [📷 Camera]
//                [🌙 Theme]  [◐ Trans]                  [✕ Close]
//
//  Capture row:
//      [Capture 120] [AI dropdown 130] [Web toggle 130]
//
//  Main area (toggleable):
//      • Default → scrollable chat history + bottom text input
//      • Browser mode → embedded WKWebView (same area)
//
//  Bottom-right has a resize grip.
//

import SwiftUI
import AppKit

struct PlaceholderPanelView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var manualFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop

            VStack(alignment: .leading, spacing: 8) {
                topBar
                captureRow
                if model.isBrowserMode {
                    browserArea
                } else {
                    chatArea
                }
                manualInputBar
            }
            .padding(.vertical, 10)

            if model.providerDropdownExpanded {
                providerDropdown
            }

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

    // MARK: - Theme colours

    private var panelBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.07, green: 0.05, blue: 0.12).opacity(0.95)
            : Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.95)
    }
    private var panelBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12)
    }
    private var primaryText:   Color { colorScheme == .dark ? .white : .black }
    private var secondaryText: Color { colorScheme == .dark ? .white.opacity(0.65) : .black.opacity(0.60) }
    private var subtleFill:    Color { colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05) }
    private var iconTint:      Color { colorScheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.78) }

    // MARK: - Backdrop

    private var backdrop: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(panelBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(panelBorderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    // MARK: - Top bar (7 icons)

    private var topBar: some View {
        HStack(spacing: 4) {
            wordmark.padding(.leading, 12)
            Spacer(minLength: 4)

            topBarIcon(symbol: "gearshape.fill",
                       action: model.onSettings,
                       help: "Settings")

            topBarIcon(symbol: activationSymbol,
                       action: model.onCycleActivation,
                       help: "Activation: \(model.activationMode.displayName)",
                       active: false)

            topBarIcon(symbol: "link",
                       action: model.onToggleContext,
                       help: "Context: \(model.contextOn ? "On" : "Off")",
                       active: model.contextOn)

            topBarIcon(symbol: "camera.fill",
                       action: model.onScreenshot,
                       help: "Capture & copy to clipboard")

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
        ["circle.fill", "circle.lefthalf.filled", "circle.dotted"][model.transparencyMode.rawValue]
    }

    /// Compact monochrome icon button.  `active=true` adds a subtle filled
    /// state so the user sees toggle status at a glance (Context icon uses
    /// this).
    private func topBarIcon(symbol: String,
                            action: @escaping () -> Void,
                            help: String,
                            isDestructive: Bool = false,
                            active: Bool = false) -> some View {
        let tint = isDestructive ? Color.red.opacity(0.75) : iconTint
        let fill = isDestructive ? Color.red.opacity(0.10) :
                   (active ? Color.blue.opacity(0.30) : subtleFill)
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
            browserToggleButton
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

    /// Browser button — toggles the embedded WKWebView in the answer area.
    private var browserToggleButton: some View {
        Button(action: { model.onToggleBrowser() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(model.isBrowserMode
                          ? Color.teal.opacity(0.55)
                          : Color.teal.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                HStack(spacing: 4) {
                    Image(systemName: model.isBrowserMode ? "globe.americas.fill" : "globe")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.isBrowserMode ? "Close Web" : "Web")
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

    // MARK: - Chat area (default)

    private var chatArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(subtleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )

            if model.chat.isEmpty && model.statusBanner == nil {
                emptyChatState
            } else {
                chatHistoryScroll
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    private var emptyChatState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundColor(secondaryText)
            Text("Click Scan, hover Capture, or type below.")
                .font(.system(size: 12))
                .foregroundColor(secondaryText)
        }
    }

    private var chatHistoryScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chat) { msg in
                        messageRow(msg)
                    }
                    if let banner = model.statusBanner {
                        thinkingRow(banner)
                            .id("thinking")
                    }
                    Color.clear.frame(height: 1).id("__bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.chat.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("__bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.statusBanner) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("__bottom", anchor: .bottom)
                }
            }
        }
    }

    private func messageRow(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top) {
            if msg.role == .user { Spacer(minLength: 32) }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 3) {
                if msg.hasImage {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                        Text("Screenshot attached")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(secondaryText)
                    .padding(.horizontal, 4)
                }
                Text(msg.text)
                    .font(.system(size: 12))
                    .foregroundColor(primaryText)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(messageBubbleColor(msg.role))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            if msg.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private func messageBubbleColor(_ role: ChatMessage.Role) -> Color {
        switch role {
        case .user:      return Color.blue.opacity(0.35)
        case .assistant: return colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color.black.opacity(0.06)
        case .system:    return Color.orange.opacity(0.18)
        }
    }

    private func thinkingRow(_ banner: String) -> some View {
        HStack(spacing: 6) {
            ThinkingDots()
            Text(banner)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(secondaryText)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Browser area

    private var browserArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)   // browser content needs a solid backdrop
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )
            BrowserWebViewRepresentable()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Manual input bar (always visible at bottom)

    private var manualInputBar: some View {
        HStack(spacing: 6) {
            // Attached-image pill (only shown when user has a queued image)
            if model.attachedImageThumb != nil {
                HStack(spacing: 4) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 10))
                    Text("Image attached")
                        .font(.system(size: 10, weight: .medium))
                    Button(action: { model.onClearAttachedImage() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundColor(.white.opacity(0.95))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.35))
                .clipShape(Capsule())
            }

            TextField("Ask anything, paste an image, then press Enter…",
                      text: $model.manualInput)
                .textFieldStyle(.plain)
                .focused($manualFocused)
                .font(.system(size: 13))
                .foregroundColor(primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(manualFocused ? Color.blue.opacity(0.5) : panelBorderColor,
                                        lineWidth: 1)
                        )
                )
                .onSubmit { submitManual() }

            Button(action: submitManual) {
                ZStack {
                    Circle()
                        .fill(model.manualInput.isEmpty
                              ? subtleFill : Color.blue.opacity(0.85))
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(model.manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func submitManual() {
        let trimmed = model.manualInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.onSubmitManualAsk(trimmed)
        model.manualInput = ""
    }
}

// =============================================================================
//  ThinkingDots — animated three-dot indicator
// =============================================================================

struct ThinkingDots: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { idx in
                Circle()
                    .fill(Color.blue.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase == idx ? 1.4 : 0.85)
                    .opacity(phase == idx ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 0.4), value: phase)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

// =============================================================================
//  BubbleView — answer-bubble (used by the bubble window, separate from panel)
// =============================================================================

struct PlaceholderBubbleView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bg: Color = colorScheme == .dark
            ? Color(red: 0.07, green: 0.05, blue: 0.12).opacity(0.93)
            : Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.95)
        let border: Color = colorScheme == .dark
            ? Color.white.opacity(0.10) : Color.black.opacity(0.12)
        let textColor: Color = colorScheme == .dark ? .white : .black

        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .overlay(
                Text(model.chat.last?.text ?? "")
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
//  ResizeGrip — bottom-right resize handle
// =============================================================================

struct ResizeGrip: View {
    let tint: Color
    @State private var startFrame: NSRect?

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let s = size.width
                let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round)
                for offset in [0.0, 0.35, 0.70] {
                    var path = Path()
                    path.move(to:    CGPoint(x: s,         y: s * offset))
                    path.addLine(to: CGPoint(x: s * offset, y: s))
                    ctx.stroke(path, with: .color(tint), style: stroke)
                }
            }
            Color.clear
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    guard let win = currentPanelWindow() else { return }
                    if startFrame == nil { startFrame = win.frame }
                    guard let s = startFrame else { return }
                    let newW = max(420, s.width  + value.translation.width)
                    let newH = max(280, s.height + value.translation.height)
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
            if hovering { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        }
    }

    private func currentPanelWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentViewController is NSHostingController<PlaceholderPanelView> }
    }
}
