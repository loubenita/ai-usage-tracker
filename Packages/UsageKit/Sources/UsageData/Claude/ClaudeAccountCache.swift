import Foundation
import UsageDomain

/// Reads the account snapshots the status line saves: each account's percentages, when they
/// were read, and the reset times when its payload had them. A snapshot older than the
/// panel's 5-hour window still says where the account stood, and an account at its limit has no
/// sessions to refresh it, so one is kept for a week and the panel says when it was read.
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
                    fiveHourPercent: five, weeklyPercent: weekly,
                    fiveHourResetsAt: resetTime(object["five_hour_resets_at"]),
                    weeklyResetsAt: resetTime(object["weekly_resets_at"])
                )
            }
    }

    /// A reset time in epoch seconds. A snapshot saved before the status line knew reset times
    /// has none, and anything that is not a usable time (a word, a boolean, zero, a negative) is
    /// left out rather than guessed.
    private static func resetTime(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        return seconds > 0 && seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }
}
