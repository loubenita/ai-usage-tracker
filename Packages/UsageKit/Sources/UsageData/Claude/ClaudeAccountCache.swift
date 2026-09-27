import Foundation
import UsageDomain

/// Reads the two local account percentage snapshots already written by Claude's status line.
/// They contain no reset time, so the UI must not invent one. Older snapshots are
/// retained briefly with an explicit stale label, rather than presented as current.
enum ClaudeAccountCache {
    static func read(homeDirectory: String, files: FileAccess, now: Date) -> [AccountUsageSnapshot] {
        let directory = homeDirectory + "/.claude/orchestrator/usage"
        return files.list(directory)
            .filter { $0.hasPrefix("account-") && $0.hasSuffix(".json") }
            .compactMap { name -> AccountUsageSnapshot? in
                guard let data = files.data(directory + "/" + name),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["config_dir"] as? String,
                      let at = (object["as_of"] as? NSNumber)?.doubleValue else { return nil }
                let readAt = Date(timeIntervalSince1970: at)
                guard now.timeIntervalSince(readAt) >= 0,
                      now.timeIntervalSince(readAt) <= 7 * 24 * 3600 else { return nil }
                let five = (object["five_hour_pct"] as? NSNumber)?.doubleValue
                let weekly = (object["weekly_pct"] as? NSNumber)?.doubleValue
                guard five != nil || weekly != nil else { return nil }
                return AccountUsageSnapshot(
                    id: id, name: ClaudeAccounts.name(for: id, homeDirectory: homeDirectory),
                    agent: .claudeCode, readAt: readAt,
                    fiveHourPercent: five, weeklyPercent: weekly
                )
            }
    }
}
