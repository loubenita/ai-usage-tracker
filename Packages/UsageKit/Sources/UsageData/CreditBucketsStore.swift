import Foundation
import Synchronization
import UsageDomain

/// Computes the local credit buckets (`CreditBuckets`) from this Mac's turns and keeps them in
/// the local cache so they survive a Kiro reset that wipes `~/.kiro/sessions`. The day figure is
/// taken live from the turns; each seven-day band is accumulated, so a band that has already
/// passed keeps its total even once the session files behind it are gone.
///
/// It is the local counterpart to the plan's authoritative monthly figure: the plan's max and
/// used stay as Kiro reports them, while this sums only the credits this Mac saw. Everything it
/// produces is labelled `CreditBuckets.scopeLabel` ("on this Mac").
final class CreditBucketsStore: Sendable {
    private let cachePath: String?
    private let calendar: Calendar
    private let cache = Mutex(CreditBucketsCache())

    /// `cachePath` nil keeps the buckets in memory only, as the history cache allows.
    init(homeDirectory: String, calendar: Calendar = .current, cachePath: String? = nil) {
        self.calendar = calendar
        self.cachePath = cachePath ?? CreditBucketsCache.path(homeDirectory: homeDirectory)
        if let path = self.cachePath, let saved = CreditBucketsCache.load(from: path) {
            cache.withLock { $0 = saved }
        }
    }

    /// Where the app keeps the local credit buckets between launches.
    static func cachePath(homeDirectory: String = NSHomeDirectory()) -> String {
        CreditBucketsCache.path(homeDirectory: homeDirectory)
    }

    /// The accumulated buckets for `selectedDay`, from the credit-bearing `turns`, anchored to
    /// the plan's reset day. Folds the fresh sums into the cache, saves it when it changed, and
    /// returns the accumulated result to show.
    func buckets(turns: [Turn], selectedDay: Date, resetsAt: Date?) -> CreditBuckets {
        let resetDay = CreditBuckets.resetDay(from: resetsAt, calendar: calendar)
        let fresh = CreditBuckets.make(turns: turns, selectedDay: selectedDay, resetDay: resetDay, calendar: calendar)
        let monthKey = CreditBucketsCache.monthKey(for: selectedDay, resetDay: resetDay, calendar: calendar)
        let (accumulated, snapshot) = cache.withLock { cache -> (CreditBuckets, CreditBucketsCache) in
            let result = cache.merge(fresh, monthKey: monthKey)
            return (result, cache)
        }
        if let cachePath { try? snapshot.save(to: cachePath) }
        return accumulated
    }
}
