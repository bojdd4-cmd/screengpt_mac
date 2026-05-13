//
//  LoginView.swift
//  ScreenGPT
//
//  SwiftUI form shown in the LoginController's NSWindow.  Email + password
//  fields, a Sign In button, an inline error label.  Hosts inside a normal
//  NSWindow (not the click-through NSPanel) because text fields need to
//  receive keyboard events.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var model: LoginModel

    @FocusState private var focusedField: Field?
    private enum Field { case email, password }

    var body: some View {
        ZStack {
            // Same dark-purple backdrop the overlay uses, for brand
            // continuity.  This window IS focusable so we draw it as a
            // proper opaque card.
            Color(red: 0.07, green: 0.05, blue: 0.12)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                // Brand wordmark — composed char-by-char so the literal
                // doesn't appear as a single string in the binary's
                // strings table.
                HStack(spacing: 0) {
                    ForEach(Array("ScreenGPT"), id: \.self) { ch in
                        Text(String(ch))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
                .padding(.top, 16)

                Text("Sign in to continue")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))

                VStack(spacing: 10) {
                    field(title: "Email",
                          text: $model.email,
                          isSecure: false,
                          focus: .email,
                          nextFocus: .password)

                    field(title: "Password",
                          text: $model.password,
                          isSecure: true,
                          focus: .password,
                          nextFocus: nil)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)

                if let err = model.errorMessage {
                    Text(err)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                signInButton
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
            }
        }
        .frame(width: 320, height: 280)
        .onAppear {
            // Auto-focus email on first appearance.  If the user re-opened
            // after an error, focus password instead so they can just retype.
            focusedField = model.email.isEmpty ? .email : .password
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func field(title: String,
                       text: Binding<String>,
                       isSecure: Bool,
                       focus: Field,
                       nextFocus: Field?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            Group {
                if isSecure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .focused($focusedField, equals: focus)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(focusedField == focus
                                    ? Color.blue.opacity(0.6)
                                    : Color.white.opacity(0.10),
                                    lineWidth: 1)
                    )
            )
            .foregroundColor(.white)
            .font(.system(size: 13))
            .onSubmit {
                if let nextFocus {
                    focusedField = nextFocus
                } else {
                    attemptSubmit()
                }
            }
        }
    }

    private var signInButton: some View {
        Button(action: attemptSubmit) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.isSubmitting
                          ? Color.blue.opacity(0.45)
                          : Color.blue.opacity(0.85))
                Text(model.isSubmitting ? "Signing in…" : "Sign In")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(height: 38)
        }
        .buttonStyle(.plain)
        .disabled(model.isSubmitting || !canSubmit)
        .opacity(canSubmit ? 1.0 : 0.6)
    }

    // MARK: - Submission

    private var canSubmit: Bool {
        !model.email.trimmingCharacters(in: .whitespaces).isEmpty
        && !model.password.isEmpty
    }

    private func attemptSubmit() {
        guard canSubmit, !model.isSubmitting else { return }
        model.errorMessage = nil
        model.isSubmitting = true
        model.submit(
            model.email.trimmingCharacters(in: .whitespaces),
            model.password
        )
    }
}
