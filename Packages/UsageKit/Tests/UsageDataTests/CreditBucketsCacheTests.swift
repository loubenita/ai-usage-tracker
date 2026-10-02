import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// The local credit buckets kept on disk so they survive a Kiro reset that wipes
/// `~/.kiro/sessions`: a band keeps the highest total it has reached, by calendar month, even
/// once the session files behind it are gone.
@Suite("The local credit buckets cache")
struct CreditBucketsCacheTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let tag = WorkTag(project: "shop", concern: "main")

    func temporaryFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("buckets-\(UUID().uuidString).json").path
    }

    func turn(_ id: String, day: Int, credits: Double) -> Turn {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
        return Turn(
            id: id, timestamp: date, agent: .kiro, sessionID: "k", model: "auto", work: Work(tag: tag),
            tokens: nil, cost: Cost(usd: nil), context: nil, credits: credits
        )
    }

    func selected(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 9))!
    }

    @Test func theMonthKeyIsAnchoredToTheResetDay() {
        // Reset on the 5th: the 2nd belongs to October's cycle, the 6th to November's.
        #expect(CreditBucketsCache.monthKey(for: selected(2), resetDay: 5, calendar: calendar) == "2026-10")
        #expect(CreditBucketsCache.monthKey(for: selected(6), resetDay: 5, calendar: calendar) == "2026-11")
        // Anchored to the 1st, every day of November is November's cycle.
        #expect(CreditBucketsCache.monthKey(for: selected(1), resetDay: 1, calendar: calendar) == "2026-11")
    }

    @Test func aBandKeepsItsHighestTotalWhenTheFilesDisappear() {
        var cache = CreditBucketsCache()
        let fresh = CreditBuckets.make(
            turns: [turn("a", day: 3, credits: 2.0)], selectedDay: selected(3), resetDay: 1, calendar: calendar
        )
        let first = cache.merge(fresh, monthKey: "2026-11")
        #expect(first.bands[0].credits == 2.0)
        // The session files vanish, so a fresh sum for the same month now finds nothing. The
        // stored band is not lowered.
        let empty = CreditBuckets.make(turns: [], selectedDay: selected(3), resetDay: 1, calendar: calendar)
        let second = cache.merge(empty, monthKey: "2026-11")
        #expect(second.bands[0].credits == 2.0)
        // A higher fresh sum does raise it.
        let higher = CreditBuckets.make(
            turns: [turn("a", day: 3, credits: 5.0)], selectedDay: selected(3), resetDay: 1, calendar: calendar
        )
        #expect(cache.merge(higher, monthKey: "2026-11").bands[0].credits == 5.0)
    }

    @Test func theCacheSurvivesSaveAndLoad() throws {
        let path = temporaryFile()
        var cache = CreditBucketsCache()
        _ = cache.merge(
            CreditBuckets.make(
                turns: [turn("a", day: 3, credits: 2.0), turn("b", day: 10, credits: 1.0)],
                selectedDay: selected(3), resetDay: 1, calendar: calendar
            ),
            monthKey: "2026-11"
        )
        try cache.save(to: path)
        let loaded = try #require(CreditBucketsCache.load(from: path))
        #expect(loaded.months["2026-11"]?["0"] == 2.0)
        #expect(loaded.months["2026-11"]?["1"] == 1.0)
    }

    @Test func aCacheOfAnotherVersionIsIgnored() throws {
        let path = temporaryFile()
        var cache = CreditBucketsCache()
        cache.version = CreditBucketsCache.version + 1
        try cache.save(to: path)
        #expect(CreditBucketsCache.load(from: path) == nil)
        #expect(CreditBucketsCache.load(from: "/nonexistent/buckets.json") == nil)
    }

    @Test func theStoreAccumulatesAcrossLaunchesThroughTheFile() {
        let path = temporaryFile()
        let october1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        // First launch: the band is summed to 2.0 and saved.
        let first = CreditBucketsStore(homeDirectory: "/unused", calendar: calendar, cachePath: path)
        let before = first.buckets(turns: [turn("a", day: 3, credits: 2.0)], selectedDay: selected(3), resetsAt: october1)
        #expect(before.bands[0].credits == 2.0)
        // Next launch after a Kiro reset wiped the sessions: no turns, but the saved band holds.
        let second = CreditBucketsStore(homeDirectory: "/unused", calendar: calendar, cachePath: path)
        let after = second.buckets(turns: [], selectedDay: selected(3), resetsAt: october1)
        #expect(after.bands[0].credits == 2.0)
        // The day figure is always live, so with no turns it is zero.
        #expect(after.day == 0)
    }
}
