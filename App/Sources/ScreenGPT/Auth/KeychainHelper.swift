//
//  KeychainHelper.swift
//  ScreenGPT
//
//  macOS Keychain wrapper for storing the user's email + password so the
//  app can auto-login after an LDB-triggered kill + launchd relaunch.
//
//  Why creds and not just the token: the brain validates the password
//  on each login request — there's no "use cached token" command.  So
//  we cache the credentials and re-submit them on relaunch.
//
//  Security: macOS Keychain encrypts the secret at rest using the user's
//  login password.  An attacker with physical access could read it iff
//  they also know the user's password.  The first read may prompt the
//  user for approval (since our app is ad-hoc signed).  After approval,
//  subsequent reads are silent for the lifetime of the keychain item.
//

import Foundation
import Security

enum KeychainHelper {

    /// Service identifier for our keychain items.  Matches the bundle ID
    /// so each disguise (com.apple.ColorCalibration → com.apple.SystemAuditAgent
    /// → etc.) has its own keychain partition — no leakage between
    /// previous installs.
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.apple.SystemAuditAgent"
    }

    /// Save email + password to the user's login keychain.  Replaces any
    /// existing item for the same service.  Safe to call repeatedly.
    @discardableResult
    static func save(email: String, password: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else { return false }

        // Delete any existing item first — SecItemUpdate is finicky with
        // missing items, easier to just delete + add.
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String:   passwordData,
            // .afterFirstUnlock — accessible after the user has logged in
            // at least once after boot.  Matches typical app behaviour.
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Try to read the saved credentials.  Returns nil if nothing's stored
    /// or the user denied keychain access.
    static func load() -> (email: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnData as String:       true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              let email = dict[kSecAttrAccount as String] as? String
        else { return nil }
        return (email, password)
    }

    /// Delete the saved credentials.  Call on logout or when stored creds
    /// have proven invalid (login_err: bad_creds).
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
