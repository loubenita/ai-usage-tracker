import Foundation
import Testing
@testable import UsageDomain

/// The local, reset-anchored credit buckets: a single day, and fixed seven-day bands counted
/// from the plan's reset day of the month. These sum only `turn.credits` and are labelled
/// "on this Mac" wherever shown.
@Suite("Local credit buckets")
struct CreditBucketsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let tag = WorkTag(project: "shop", concern: "main")

    /// A Kiro turn billed `credits` on the given day of November 2026.
    func turn(_ id: String, day: Int, credits: Double?) -> Turn {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
        return Turn(
            id: id, timestamp: date, agent: .kiro, sessionID: "k", model: "auto", work: Work(tag: tag),
            tokens: nil, cost: Cost(usd: nil), context: nil, credits: credits
        )
    }

    @Test func theBandsRunFromTheResetDayInSevensToTheMonthsEnd() {
        // Anchored to the 1st: the plain calendar-week bands of a month.
        #expect(CreditBuckets.bandRanges(resetDay: 1).map { [$0.firstDay, $0.lastDay] }
            == [[1, 7], [8, 14], [15, 21], [22, 28], [29, 31]])
        // A reset day is clamped to at most the 28th so the first band fits every month.
        #expect(CreditBuckets.bandRanges(resetDay: 31).map(\.firstDay) == [28])
        // The reset day comes from the plan's resetsAt, or the 1st without one.
        let nov1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        #expect(CreditBuckets.resetDay(from: nov1, calendar: calendar) == 1)
        #expect(CreditBuckets.resetDay(from: nil, calendar: calendar) == 1)
    }

    @Test func theDayAndBandsSumOnlyCredits() {
        let selected = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
        let turns = [
            turn("a", day: 3, credits: 0.5),
            turn("b", day: 3, credits: 0.25),
            // A turn without credits counts as none, not zero.
            turn("c", day: 3, credits: nil),
            turn("d", day: 10, credits: 2.0),
            turn("e", day: 20, credits: 4.0),
        ]
        let buckets = CreditBuckets.make(turns: turns, selectedDay: selected, resetDay: 1, calendar: calendar)
        // The 3rd: 0.5 + 0.25.
        #expect(buckets.day == 0.75)
        // Bands 1-7, 8-14, 15-21, 22-28, 29-31.
        #expect(buckets.bands.map(\.credits) == [0.75, 2.0, 4.0, 0.0, 0.0])
        // The selected day is in the first band.
        #expect(buckets.currentBandIndex == 0)
    }

    @Test func theBandsAreAnchoredToANonFirstResetDay() {
        // Reset on the 5th: bands 5-11, 12-18, 19-25, 26-31.
        let selected = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        let turns = [turn("a", day: 6, credits: 1.0), turn("b", day: 14, credits: 2.0)]
        let buckets = CreditBuckets.make(turns: turns, selectedDay: selected, resetDay: 5, calendar: calendar)
        #expect(buckets.bands.map { [$0.firstDay, $0.lastDay] } == [[5, 11], [12, 18], [19, 25], [26, 31]])
        #expect(buckets.bands.map(\.credits) == [1.0, 2.0, 0.0, 0.0])
        // The 14th falls in the second band, 12-18.
        #expect(buckets.currentBandIndex == 1)
        // A day before the anchor is in no band of this cycle.
        let early = CreditBuckets.make(
            turns: [turn("c", day: 2, credits: 9.0)],
            selectedDay: calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!,
            resetDay: 5, calendar: calendar
        )
        #expect(early.bands.allSatisfy { $0.credits == 0 })
        #expect(early.currentBandIndex == nil)
    }
}
