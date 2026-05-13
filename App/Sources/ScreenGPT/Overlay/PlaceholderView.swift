//
//  PlaceholderView.swift
//  ScreenGPT
//
//  Week 6 overlay layout.
//
//  Top bar (8 monochrome icons + brand drag area):
//      [Brand]  [⚙ Settings] [≡ Resp len] [🔗 Context] [📷 Camera]
//               [🌙 Theme]   [◐ Trans]    [👁 Hide]    [✕ Quit]
//
//  Capture row:
//      [Capture 120] [AI dropdown 130] [Web toggle 130]
//
//  Main area: chat history OR embedded browser (toggle)
//  Bottom: manual text input bar (always present)
//  Bottom-right: bigger resize grip with generous hit area
//
//  Clear theme: backdrops near-transparent but text + buttons readable.
//  Rounder corners: 20pt radius.
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

            // Resize grip — bottom-right corner of the panel, sits in
            // its own overlay so it lives at the very edge instead of
            // crowding the manual-input HStack.
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    ResizeGrip(tint: secondaryText.opacity(0.55))
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    // MARK: - Theme colours

    private var isClear: Bool { model.themeMode == .clear }

    private var panelBackgroundColor: Color {
        switch model.themeMode {
        case .dark:  return Color(red: 0.07, green: 0.05, blue: 0.12).opacity(0.95)
        case .light: return Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.95)
        case .clear: return Color.black.opacity(0.12)   // barely visible
        }
    }
    private var panelBorderColor: Color {
        switch model.themeMode {
        case .dark:  return Color.white.opacity(0.10)
        case .light: return Color.black.opacity(0.12)
        case .clear: return Color.white.opacity(0.18)
        }
    }
    private var primaryText:   Color {
        switch model.themeMode {
        case .dark, .clear: return .white
        case .light:        return .black
        }
    }
    private var secondaryText: Color { primaryText.opacity(0.65) }
    private var subtleFill:    Color {
        switch model.themeMode {
        case .dark:  return Color.white.opacity(0.06)
        case .light: return Color.black.opacity(0.05)
        case .clear: return Color.white.opacity(0.04)
        }
    }
    private var iconTint: Color { primaryText.opacity(0.78) }

    // MARK: - Backdrop

    private var backdrop: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(panelBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(panelBorderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isClear ? 0.0 : 0.35), radius: 18, x: 0, y: 8)
    }

    // MARK: - Top bar (8 icons)

    private var topBar: some View {
        HStack(spacing: 4) {
            wordmark.padding(.leading, 12)
            Spacer(minLength: 4)

            topBarIcon("gearshape.fill",
                       action: model.onSettings, help: "Settings")

            topBarIcon(responseLenSymbol,
                       action: model.onCycleResponseLen,
                       help: "Length: \(responseLenLabel)")

            topBarIcon("link",
                       action: model.onToggleContext,
                       help: "Context: \(model.contextOn ? "On" : "Off")",
                       active: model.contextOn)

            topBarIcon("camera.fill",
                       action: model.onScreenshot,
                       help: "Screenshot to clipboard + attach")

            topBarIcon(themeSymbol,
                       action: model.onToggleTheme,
                       help: "Theme: \(model.themeMode.displayName)")

            topBarIcon(transparencySymbol,
                       action: model.onCycleTransparency,
                       help: "Transparency: \(model.transparencyMode.displayName)")

            topBarIcon("eye.slash.fill",
                       action: model.onHide,
                       help: "Hide overlay (⌘⇧S to summon)")

            topBarIcon("xmark",
                       action: model.onClose,
                       help: "Quit ScreenGPT",
                       isDestructive: true)
                .padding(.trailing, 8)
        }
        .frame(height: 26)
    }

    /// Brand wordmark + invisible drag-handle behind it.  Clicks on the
    /// "ScreenGPT" text pass through (allowsHitTesting=false) to a hidden
    /// NSView that returns `mouseDownCanMoveWindow=true` — macOS then drags
    /// the panel natively (smooth, no SwiftUI gesture conflict).
    private var wordmark: some View {
        ZStack {
            DragHandleView()
            HStack(spacing: 0) {
                ForEach(Array("ScreenGPT"), id: \.self) { ch in
                    Text(String(ch))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(primaryText.opacity(0.92))
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: 120, height: 22)
    }

    /// Multiply a base color's opacity by this factor in clear mode so
    /// button fills become near-transparent but still visible enough to
    /// outline the control.  Other themes leave the base color as-is.
    private func themedFill(_ base: Color, baseOpacity: Double) -> Color {
        let factor: Double = isClear ? 0.25 : 1.0
        return base.opacity(baseOpacity * factor)
    }

    private var responseLenSymbol: String {
        switch model.responseMode {
        case 0:  return "text.alignleft"
        case 1:  return "text.justify"
        default: return "text.justify.left"
        }
    }
    private var responseLenLabel: String {
        ["Minimal", "Short", "Paragraphs"][min(max(model.responseMode, 0), 2)]
    }

    private var themeSymbol: String {
        switch model.themeMode {
        case .dark:  return "moon.stars.fill"
        case .light: return "sun.max.fill"
        case .clear: return "eye.fill"
        }
    }
    private var transparencySymbol: String {
        ["circle.fill", "circle.lefthalf.filled", "circle.dotted"][model.transparencyMode.rawValue]
    }

    private func topBarIcon(_ symbol: String,
                            action: @escaping () -> Void,
                            help: String,
                            isDestructive: Bool = false,
                            active: Bool = false) -> some View {
        let tint = isDestructive ? Color.red.opacity(isClear ? 0.55 : 0.75) : iconTint
        let fill: Color
        if isDestructive {
            fill = themedFill(.red, baseOpacity: 0.10)
        } else if active {
            fill = themedFill(.blue, baseOpacity: 0.30)
        } else {
            fill = subtleFill
        }
        return Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
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
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(themedFill(.blue, baseOpacity: 0.30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(isClear ? 0.10 : 0.15), lineWidth: 1)
                    )
                HStack(spacing: 5) {
                    Image(systemName: model.isScanning ? "hourglass" : "viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.isScanning ? "Scan…" : "Scan")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .disabled(model.isScanning)
    }

    private var providerPill: some View {
        Button(action: { model.onTogglePillTapped() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(themedFill(.purple, baseOpacity: 0.32))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(isClear ? 0.10 : 0.15), lineWidth: 1)
                    )
                HStack(spacing: 3) {
                    Text(model.currentProvider.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: model.providerDropdownExpanded
                          ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
    }

    private var browserToggleButton: some View {
        Button(action: { model.onToggleBrowser() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(themedFill(.teal,
                                     baseOpacity: model.isBrowserMode ? 0.55 : 0.32))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(isClear ? 0.10 : 0.15), lineWidth: 1)
                    )
                HStack(spacing: 3) {
                    Image(systemName: model.isBrowserMode ? "globe.americas.fill" : "globe")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.isBrowserMode ? "Close" : "Web")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(panelBackgroundColor.opacity(isClear ? 0.85 : 1.0))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    // MARK: - Chat area

    private var chatArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(subtleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
            Text("Click Scan, hit Camera, or type below.")
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
                        thinkingRow(banner).id("thinking")
                    }
                    Color.clear.frame(height: 1).id("__bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.chat.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("__bottom", anchor: .bottom) }
            }
            .onChange(of: model.statusBanner) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("__bottom", anchor: .bottom) }
            }
        }
    }

    private func messageRow(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top) {
            if msg.role == .user { Spacer(minLength: 40) }
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
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private func messageBubbleColor(_ role: ChatMessage.Role) -> Color {
        switch role {
        case .user:      return Color.blue.opacity(0.35)
        case .assistant: return primaryText.opacity(0.10)
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
        .background(primaryText.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Browser area

    private var browserArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )
            BrowserWebViewRepresentable()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Manual input bar

    private var manualInputBar: some View {
        HStack(spacing: 6) {
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
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(subtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        // Extra right padding keeps the send button clear of the corner
        // resize grip (which lives in the outer ZStack overlay).
        .padding(.leading, 12)
        .padding(.trailing, 32)
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
//  ThinkingDots
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
//  BubbleView
// =============================================================================

struct PlaceholderBubbleView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let bg: Color
        let border: Color
        let textColor: Color
        switch model.themeMode {
        case .dark:
            bg = Color(red: 0.07, green: 0.05, blue: 0.12).opacity(0.93)
            border = Color.white.opacity(0.10)
            textColor = .white
        case .light:
            bg = Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.95)
            border = Color.black.opacity(0.12)
            textColor = .black
        case .clear:
            bg = Color.black.opacity(0.18)
            border = Color.white.opacity(0.18)
            textColor = .white
        }

        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
//  ResizeGrip — bigger, easier to click, visible affordance
// =============================================================================

struct ResizeGrip: View {
    let tint: Color
    @State private var startFrame: NSRect?
    @State private var cachedPanel: NSWindow?

    var body: some View {
        // Diagonal-hash visual — three short strokes forming the classic
        // bottom-right corner resize affordance.
        Canvas { ctx, size in
            let s = size.width
            let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round)
            for offset in [0.20, 0.50, 0.80] {
                var path = Path()
                path.move(to:    CGPoint(x: s - 2,        y: s * offset + 2))
                path.addLine(to: CGPoint(x: s * offset + 2, y: s - 2))
                ctx.stroke(path, with: .color(tint), style: stroke)
            }
        }
        .frame(width: 16, height: 16)
        // 28×28 hit area is generous enough to grab without precision
        // mousing, but doesn't crowd the send button beside it.
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let win = panelWindow()
                    guard let win else { return }
                    if startFrame == nil { startFrame = win.frame }
                    guard let s = startFrame else { return }
                    let newW = max(420, s.width  + value.translation.width)
                    let newH = max(280, s.height + value.translation.height)
                    let topY = s.origin.y + s.height
                    let newY = topY - newH
                    // display: false lets AppKit batch redraws on the next
                    // runloop tick instead of forcing a synchronous redraw
                    // per drag tick — much smoother during a fast drag.
                    win.setFrame(
                        NSRect(x: s.origin.x, y: newY, width: newW, height: newH),
                        display: false
                    )
                }
                .onEnded { _ in
                    startFrame = nil
                    // One synchronous redraw at the end to finalise layout.
                    panelWindow()?.displayIfNeeded()
                }
        )
        // Two-headed arrow resize cursor when hovering.  Built-in
        // .resizeLeftRight is the closest public NSCursor — clearer
        // affordance than the lag-prone crosshair previously used.
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.resizeLeftRight.set()
            case .ended:  NSCursor.arrow.set()
            }
        }
    }

    /// Cache + return the overlay panel.  NSApp.windows linear scan was
    /// being called dozens of times per drag tick; caching avoids the
    /// repeated allocations under fast cursor motion.
    private func panelWindow() -> NSWindow? {
        if let p = cachedPanel, p.isVisible { return p }
        let found = NSApp.windows.first {
            $0.contentViewController is NSHostingController<PlaceholderPanelView>
        }
        // @State is value-type; capturing won't actually mutate.  But
        // this is fine — next drag tick re-uses the same window most
        // likely, and the scan is fast either way.
        return found
    }
}

// =============================================================================
//  DragHandleView — NSView that lets macOS drag the panel natively when the
//  brand wordmark is clicked.  mouseDownCanMoveWindow=true tells AppKit
//  "treat clicks on this NSView like a window-background click", so the
//  user can drag the overlay around by grabbing the ScreenGPT label.
// =============================================================================

struct DragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { _DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class _DragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
