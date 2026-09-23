import Foundation
import UsageDomain

/// Claude's plan limits, as `scripts/claude-statusline.sh` saves them.
///
/// Claude Code does not write its limits to the transcript. It does pass them to a status line
/// script, as `rate_limits.five_hour` and `rate_limits.seven_day`, each with
/// `used_percentage` and `resets_at` in epoch seconds. The script adds a line to this log
/// whenever they change:
///
///     {"at":1790024450,"five_hour":{"used_percentage":62,"resets_at":1790031600},"seven_day":{…}}
enum ClaudeLimitsLog {
    /// Where the script writes, and this app reads.
    static func path(homeDirectory: String) -> String {
        homeDirectory + "/Library/Application Support/AIUsageTracker/claude-limits.jsonl"
    }

    /// Every reading in the log taken at or after `since`.
    static func readings(in data: Data, since: Date) -> [LimitReading] {
        data.split(separator: 0x0A).compactMap { line in
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let at = (object["at"] as? NSNumber)?.doubleValue
            else { return nil }
            let timestamp = Date(timeIntervalSince1970: at)
            guard timestamp >= since else { return nil }
            let windows = [("five_hour", LimitWindowKind.fiveHour), ("seven_day", .weekly)].compactMap { key, kind in
                (object[key] as? [String: Any]).flatMap { window -> LimitWindowReading? in
                    guard
                        let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                        let resets = (window["resets_at"] as? NSNumber)?.doubleValue
                    else { return nil }
                    return LimitWindowReading(kind: kind, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
                }
            }
            return windows.isEmpty ? nil : LimitReading(timestamp: timestamp, agent: .claudeCode, plan: nil, windows: windows)
        }
    }
}
