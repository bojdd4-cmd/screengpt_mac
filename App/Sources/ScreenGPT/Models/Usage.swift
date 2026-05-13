//
//  Usage.swift
//  ScreenGPT
//
//  Token-usage info from screenai.site, emitted by the brain on every
//  successful scan (`usage` event) and on demand via `fetch_usage`
//  (`usage_full` event).
//

import Foundation

/// Per-provider usage data from a single `usage` event.
struct UsageSnapshot: Equatable, Sendable {
    let provider: Provider
    let used: Int
    let limit: Int?
    let remaining: Int?

    /// Fraction of the limit consumed, in [0, 1]. Returns 0 if `limit` is nil
    /// or 0 (e.g. unlimited plans).
    var ratio: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(1.0, Double(used) / Double(limit))
    }
}

/// Full snapshot from `/api/usage`, keyed by provider name.
struct UsageReport: Equatable, Sendable {
    var byProvider: [Provider: UsageSnapshot] = [:]

    static func fromBrainPayload(_ raw: [String: Any]) -> UsageReport {
        var out = UsageReport()
        for (key, value) in raw {
            guard let provider = Provider(rawValue: key),
                  let entry    = value as? [String: Any] else { continue }
            out.byProvider[provider] = UsageSnapshot(
                provider:  provider,
                used:      entry["used"]      as? Int ?? 0,
                limit:     entry["limit"]     as? Int,
                remaining: entry["remaining"] as? Int
            )
        }
        return out
    }
}
