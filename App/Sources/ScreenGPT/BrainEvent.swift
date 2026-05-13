//
//  BrainEvent.swift
//  ScreenGPT
//
//  Typed event enum matching the JSON event names produced by
//  ../Brain/screenai_brain.py. See Brain/README.md for the full spec.
//

import Foundation

enum BrainEvent: Sendable {
    case ready(version: String)

    case loginOK(token: String)
    case loginErr(code: String, msg: String)
    case loggedOut

    case scanProgress(stage: String)
    case scanOK(
        answer: String,
        provider: String,
        tokensUsed: Int?,
        tokensRemaining: Int?
    )
    case scanErr(msg: String)

    case usage(provider: String, used: Int, limit: Int?, remaining: Int?)
    case usageFull(data: [String: Any])

    case settingValue(key: String, value: Any?)
    case allSettings(values: [String: Any])

    case machineId(value: String)
    case pong(t: Double)
    case shutdownOk

    case log(level: String, msg: String)
    case unknown(name: String, payload: [String: Any])

    // MARK: - Decoding

    static func decode(_ obj: [String: Any]) -> BrainEvent {
        let name = obj["evt"] as? String ?? ""

        switch name {

        case "ready":
            return .ready(version: obj["version"] as? String ?? "")

        case "login_ok":
            return .loginOK(token: obj["token"] as? String ?? "")

        case "login_err":
            return .loginErr(
                code: obj["code"] as? String ?? "unknown",
                msg:  obj["msg"]  as? String ?? ""
            )

        case "logged_out":
            return .loggedOut

        case "scan_progress":
            return .scanProgress(stage: obj["stage"] as? String ?? "")

        case "scan_ok":
            return .scanOK(
                answer:          obj["answer"]            as? String ?? "",
                provider:        obj["provider"]          as? String ?? "",
                tokensUsed:      obj["tokens_used"]       as? Int,
                tokensRemaining: obj["tokens_remaining"]  as? Int
            )

        case "scan_err":
            return .scanErr(msg: obj["msg"] as? String ?? "")

        case "usage":
            return .usage(
                provider:  obj["provider"]         as? String ?? "",
                used:      obj["tokens_used"]      as? Int    ?? 0,
                limit:     obj["tokens_limit"]     as? Int,
                remaining: obj["tokens_remaining"] as? Int
            )

        case "usage_full":
            return .usageFull(data: obj["data"] as? [String: Any] ?? [:])

        case "setting_value":
            return .settingValue(
                key:   obj["key"]   as? String ?? "",
                value: obj["value"]
            )

        case "all_settings":
            return .allSettings(values: obj["values"] as? [String: Any] ?? [:])

        case "machine_id":
            return .machineId(value: obj["value"] as? String ?? "")

        case "pong":
            return .pong(t: obj["t"] as? Double ?? 0)

        case "shutdown_ok":
            return .shutdownOk

        case "log":
            return .log(
                level: obj["level"] as? String ?? "info",
                msg:   obj["msg"]   as? String ?? ""
            )

        default:
            return .unknown(name: name, payload: obj)
        }
    }
}
