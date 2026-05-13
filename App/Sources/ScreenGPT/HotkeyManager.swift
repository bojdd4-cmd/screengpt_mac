//
//  HotkeyManager.swift
//  ScreenGPT
//
//  Carbon RegisterEventHotKey wrapper.  Carbon's hot-key API is used (not
//  NSEvent's addGlobalMonitorForEvents) for two reasons:
//
//      1. Stealth — NSEvent global monitors require Accessibility permission
//         AND are enumerable via event-tap inspection tools.  Carbon's
//         RegisterEventHotKey is OS-internal and invisible to event-tap
//         scanners.  CloakGPT uses this same path.
//
//      2. Works from .accessory apps — global keyboard monitors via NSEvent
//         are flaky for background apps.  Carbon's HIToolbox event target
//         is rock-solid.
//
//  Usage:
//      let mgr = HotkeyManager()
//      mgr.register(keyCode: kVK_ANSI_S, modifiers: cmdKey | shiftKey) {
//          // ⌘⇧S pressed — toggle overlay
//      }
//
//  Re-register at runtime to support user-rebindable hotkeys (week 4).
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {

    /// FourCC signature for our hotkeys.  Arbitrary but stable so we can
    /// distinguish our events from anything else in the application's event
    /// target.  Reads as 'sgpt'.
    private static let signature: OSType = 0x73677074

    private struct Slot {
        let id: UInt32
        var ref: EventHotKeyRef?
        let callback: () -> Void
    }

    /// Map of hotkey-ID → slot.  Keyed by the integer ID we hand to Carbon.
    /// Held statically so the C event-handler callback can find the closure.
    nonisolated(unsafe) private static var slots: [UInt32: Slot] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerRef: EventHandlerRef?
    private static let slotsLock = NSLock()

    /// Register a new hotkey.  Returns an opaque token the caller can use to
    /// unregister later (week 4 for user-rebinding).  Safe to call from
    /// `applicationDidFinishLaunching`.
    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  action: @escaping () -> Void) -> UInt32 {

        Self.installHandlerIfNeeded()

        Self.slotsLock.lock()
        let id = Self.nextID
        Self.nextID += 1
        Self.slotsLock.unlock()

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            // Likely cause: the same key+modifiers is already grabbed by
            // another process (Spotlight, an existing instance of us, etc.)
            NSLog("[HotkeyManager] RegisterEventHotKey failed: status=\(status)")
            return 0
        }
        _ = hotKeyID  // silence unused-mutable warning

        Self.slotsLock.lock()
        Self.slots[id] = Slot(id: id, ref: ref, callback: action)
        Self.slotsLock.unlock()

        return id
    }

    /// Unregister a previously-installed hotkey by token.  No-op for
    /// unknown tokens.  Useful for user-rebinding flows.
    func unregister(_ token: UInt32) {
        Self.slotsLock.lock()
        defer { Self.slotsLock.unlock() }
        if let slot = Self.slots[token], let ref = slot.ref {
            UnregisterEventHotKey(ref)
            Self.slots.removeValue(forKey: token)
        }
    }

    // MARK: - Carbon event handler plumbing

    /// Install the application-wide hot-key event handler once.  It runs on
    /// the main thread; we dispatch through to the callback registered for
    /// the firing hotkey's ID.
    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ -> OSStatus in
                guard let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard getStatus == noErr,
                      hotKeyID.signature == HotkeyManager.signature
                else { return noErr }

                HotkeyManager.slotsLock.lock()
                let cb = HotkeyManager.slots[hotKeyID.id]?.callback
                HotkeyManager.slotsLock.unlock()

                if let cb {
                    DispatchQueue.main.async { cb() }
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    }
}

// MARK: - Convenience

extension HotkeyManager {
    /// Register the default ⌘⇧S toggle hotkey.  Matches the Windows version's
    /// CTRL+SHIFT+S which used to raise the launcher there.
    @discardableResult
    func registerToggle(_ action: @escaping () -> Void) -> UInt32 {
        register(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | shiftKey),
            action: action
        )
    }
}
