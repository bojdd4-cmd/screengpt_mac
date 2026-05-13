//
//  LoginModel.swift
//  ScreenGPT
//
//  Observable state for the login window.  AppDelegate owns one instance,
//  hands it to LoginController for the SwiftUI binding, and reads results
//  back via the `submit` closure + `errorMessage` field.
//

import SwiftUI

@MainActor
final class LoginModel: ObservableObject {
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var errorMessage: String? = nil
    @Published var isSubmitting: Bool = false

    /// Called when the user clicks "Sign In" or presses Enter.  AppDelegate
    /// hooks this up to `brain.send(["cmd":"login", ...])`.  The model
    /// stays alive until login succeeds — re-entries (retry after a failed
    /// attempt) are fine.
    var submit: (_ email: String, _ password: String) -> Void = { _, _ in }
}
