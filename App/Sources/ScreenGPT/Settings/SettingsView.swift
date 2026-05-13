//
//  SettingsView.swift
//  ScreenGPT
//
//  SwiftUI form for the Settings panel.  Binds directly to the live
//  OverlayModel so the overlay updates immediately as the user toggles
//  controls — no apply/cancel button required.  The model's
//  `onSettingsChanged*` closures push each change down to the brain so
//  it's persisted on disk.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: OverlayModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.05, blue: 0.12)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section(title: "Activation",
                                hint: "How buttons fire — click them, hover for 1.5s, or both.") {
                            activationPicker
                        }

                        section(title: "AI Response Length",
                                hint: "How much detail each scan returns.") {
                            responsePicker
                        }

                        section(title: "AI Provider",
                                hint: "Which model handles your scans.") {
                            providerPicker
                        }

                        section(title: "Theme",
                                hint: "Panel colour scheme.") {
                            themePicker
                        }

                        section(title: "Transparency",
                                hint: "How see-through the overlay is.") {
                            transparencyPicker
                        }

                        Divider().padding(.vertical, 6)

                        hotkeyHint
                    }
                    .padding(.vertical, 4)
                }

                Spacer()
                doneButton
            }
            .padding(20)
        }
        .frame(width: 380, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("Settings")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
        }
    }

    // MARK: - Section primitive

    @ViewBuilder
    private func section<Content: View>(title: String,
                                         hint: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            content()
            Text(hint)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    // MARK: - Pickers

    private var activationPicker: some View {
        segmented(
            options: ActivationMode.allCases.map { ($0.rawValue, $0.displayName) },
            current: model.activationMode.rawValue
        ) { raw in
            if let m = ActivationMode(rawValue: raw) {
                model.onSettingsChangedActivation(m)
            }
        }
    }

    private var responsePicker: some View {
        segmented(
            options: [(0, "Minimal"), (1, "Short"), (2, "Paragraphs")],
            current: model.responseMode
        ) { raw in
            model.onSettingsChangedResponse(raw)
        }
    }

    private var providerPicker: some View {
        segmented(
            options: Provider.allCases.map { (Int($0.byteValue), $0.displayName) },
            current: Int(model.currentProvider.byteValue)
        ) { raw in
            if let p = Provider.allCases.first(where: { Int($0.byteValue) == raw }) {
                model.onSettingsChangedProvider(p)
            }
        }
    }

    private var themePicker: some View {
        segmented(
            options: ThemeMode.allCases.map { ($0.rawValue, $0.displayName) },
            current: model.themeMode.rawValue
        ) { raw in
            if let t = ThemeMode(rawValue: raw) {
                model.onSettingsChangedTheme(t)
            }
        }
    }

    private var transparencyPicker: some View {
        segmented(
            options: TransparencyMode.allCases.map { ($0.rawValue, $0.displayName) },
            current: model.transparencyMode.rawValue
        ) { raw in
            if let t = TransparencyMode(rawValue: raw) {
                model.onSettingsChangedTransparency(t)
            }
        }
    }

    // MARK: - Segmented picker primitive

    private func segmented(options: [(Int, String)],
                           current: Int,
                           onPick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { (raw, label) in
                Button(action: { onPick(raw) }) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(raw == current
                                      ? Color.blue.opacity(0.55)
                                      : Color.white.opacity(0.08))
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Hotkey hint

    private var hotkeyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            HStack {
                shortcutChip("⌘⇧S")
                Text("Toggle overlay")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
            }
            Text("Rebindable hotkeys coming in the next update.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func shortcutChip(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
            .foregroundColor(.white.opacity(0.85))
    }

    // MARK: - Done button

    private var doneButton: some View {
        Button(action: onClose) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.blue.opacity(0.80))
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(height: 36)
        }
        .buttonStyle(.plain)
    }
}
