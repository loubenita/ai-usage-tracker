import Foundation
import UsageDomain

/// The local credit buckets kept on disk so they survive a Kiro reset that wipes
/// `~/.kiro/sessions`. Kiro's session files are the only source of per-turn credits on this
/// Mac, so once they are gone a band that has already passed could no longer be summed. This
/// cache keeps the highest total each band has reached, by calendar month, and accumulates:
/// a stored band is never lowered when the files behind it vanish, only raised when fresh
/// sums are higher.
///
/// Kept in `~/Library/Application Support/AIUsageTracker/credit-buckets.json`, beside the
/// history cache. A cache written by another version of the app is ignored, as `HistoryCache`
/// does, so a change to the shape discards old data rather than trusting it.
struct CreditBucketsCache: Codable {
    static let version = 1

    var version = CreditBucketsCache.version
    /// Band totals by month key ("2026-11") then band index ("0"), each the highest seen.
    var months: [String: [String: Double]] = [:]

    static func path(homeDirectory: String) -> String {
        homeDirectory + "/Library/Application Support/AIUsageTracker/credit-buckets.json"
    }

    /// The saved cache, or nil when there is none, it cannot be read, or it is another version's.
    static func load(from path: String) -> CreditBucketsCache? {
        guard
            let data = FileManager.default.contents(atPath: path),
            let cache = try? JSONDecoder().decode(CreditBucketsCache.self, from: data),
            cache.version == version
        else { return nil }
        return cache
    }

    /// Writes the cache in one step, so a crash mid-write leaves the last good one.
    func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// A month key from the start of the cycle the selected day sits in. The cycle begins on
    /// the reset day of the month, so a day before that reset day belongs to the previous
    /// month's cycle.
    static func monthKey(for selectedDay: Date, resetDay: Int, calendar: Calendar) -> String {
        let anchor = min(max(resetDay, 1), 28)
        let components = calendar.dateComponents([.year, .month, .day], from: selectedDay)
        var year = components.year ?? 0
        var month = components.month ?? 1
        if (components.day ?? 1) < anchor {
            month -= 1
            if month < 1 { month = 12; year -= 1 }
        }
        return String(format: "%04d-%02d", year, month)
    }

    /// Folds freshly summed bands into the cache, keeping the higher total for each, and returns
    /// the accumulated buckets to show. The day figure is live (never cached, since a single
    /// past day is not shown), while each band is the greater of the fresh sum and the stored one.
    mutating func merge(_ fresh: CreditBuckets, monthKey: String) -> CreditBuckets {
        var stored = months[monthKey] ?? [:]
        let bands = fresh.bands.enumerated().map { index, band -> CreditBuckets.Band in
            let key = "\(index)"
            let accumulated = max(stored[key] ?? 0, band.credits)
            stored[key] = accumulated
            return CreditBuckets.Band(firstDay: band.firstDay, lastDay: band.lastDay, credits: accumulated)
        }
        months[monthKey] = stored
        return CreditBuckets(day: fresh.day, bands: bands, currentBandIndex: fresh.currentBandIndex)
    }
}
