import Foundation
import Testing
@testable import UsageDomain

private let hour: TimeInterval = 3600
private let base = Date(timeIntervalSince1970: 1_790_000_000)

private func reading(_ offsetHours: Double, _ kind: LimitWindowKind, _ percent: Double, resets: Date) -> LimitReading {
    LimitReading(
        timestamp: base.addingTimeInterval(offsetHours * hour),
        agent: .claudeCode,
        plan: "max",
        windows: [LimitWindowReading(kind: kind, usedPercent: percent, resetsAt: resets)]
    )
}

@Suite("How much of a limit a span of time used")
struct LimitUsageTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Midnight UTC, Monday 21 September 2026.
    let midnight = Date(timeIntervalSince1970: 1_789_948_800)

    func weekly(_ hours: Double, _ percent: Double, resets: Date) -> LimitReading {
        LimitReading(
            timestamp: midnight.addingTimeInterval(hours * hour), agent: .codex, plan: nil,
            windows: [LimitWindowReading(kind: .weekly, usedPercent: percent, resetsAt: resets)]
        )
    }

    @Test func startsFromTheLastReadingBeforeTheSpan() {
        let resets = midnight + 3 * 24 * hour
        // 29% last night; 31% and 36% today: 7 points today, not 5.
        let readings = [weekly(-3, 29, resets: resets), weekly(9, 31, resets: resets), weekly(20, 36, resets: resets)]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 7)
    }

    @Test func withNoReadingBeforeTheSpanStartsFromTheFirstInIt() {
        let resets = midnight + 3 * 24 * hour
        let readings = [weekly(9, 36, resets: resets), weekly(20, 68, resets: resets)]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 32)
    }

    @Test func aResetStartsAgainAndNeverCountsNegative() {
        let old = midnight + 12 * hour
        let new = old + 7 * 24 * hour
        // 80% before the reset at noon, 10% after it: 5 before it and 10 since.
        let readings = [weekly(-1, 75, resets: old), weekly(11, 80, resets: old), weekly(15, 10, resets: new)]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 15)
        // A window that began before the day, with no reading before it, counts from its first
        // reading today: 54% to 60% is 6 points, not 60.
        let moved = [weekly(-1, 68, resets: old), weekly(5, 54, resets: midnight + 2 * 24 * hour), weekly(20, 60, resets: midnight + 2 * 24 * hour)]
        #expect(LimitUsage.used(.weekly, in: moved, from: midnight, to: midnight + 23 * hour) == 6)
    }

    @Test func resetTimesAFewSecondsApartAreOneWindow() {
        // As Codex wrote them on 17 September: 06:56:42, 06:57:09 and 06:57:13 for one window.
        let reset = midnight + 3 * 24 * hour
        let readings = [
            weekly(-1, 54, resets: reset - 27), weekly(9, 70, resets: reset), weekly(17, 92, resets: reset + 4),
        ]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 38)
        let report = LimitForecast.report(.weekly, from: readings, calendar: calendar)
        // All three readings are one period, so the pace uses all of them.
        #expect(abs((report?.percentPerHour ?? 0) - 38.0 / 18) < 1e-9)
    }

    @Test func aWindowThatStartsAgainMidDayAddsToTheDay() {
        // As on 16 September: 68% overnight, up to 99%, then a new week at 0% from 16:52 that
        // reached 73% by midnight. That day used 31 + 73 points, more than a week's worth.
        let old = midnight + 3 * 24 * hour
        let new = midnight + (16 + 7 * 24) * hour
        let readings = [
            weekly(-4, 68, resets: old), weekly(16, 99, resets: old),
            weekly(16.9, 0, resets: new), weekly(23.9, 73, resets: new),
        ]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 24 * hour - 1) == 104)
    }

    @Test func aSessionThatIsBehindDoesNotLowerTheCount() {
        // Two sessions write the same window; the one a minute behind still says 36%.
        let resets = midnight + 3 * 24 * hour
        let readings = [weekly(-1, 30, resets: resets), weekly(10, 37, resets: resets), weekly(10.01, 36, resets: resets)]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 7)
    }

    @Test func aReadingThatFallsWithinOnePeriodCountsAsNoUse() {
        // Same reset time, but the percentage came down, as when a provider corrects it.
        let resets = midnight + 3 * 24 * hour
        let readings = [weekly(-1, 50, resets: resets), weekly(10, 45, resets: resets)]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 0)
    }

    @Test func noReadingTodayIsZeroAndNoReadingEverIsUnknown() {
        let readings = [weekly(-5, 40, resets: midnight + 3 * 24 * hour)]
        #expect(LimitUsage.used(.weekly, in: readings, from: midnight, to: midnight + 23 * hour) == 0)
        #expect(LimitUsage.used(.weekly, in: [], from: midnight, to: midnight + 23 * hour) == nil)
        #expect(LimitUsage.used(.fiveHour, in: readings, from: midnight, to: midnight + 23 * hour) == nil)
    }

    @Test func eachDayOfTheWeekCountsItsOwnUse() throws {
        let resets = midnight + 3 * 24 * hour
        let readings = [
            weekly(-6 * 24 - 1, 10, resets: resets), weekly(-2 * 24 + 5, 20, resets: resets),
            weekly(-2 * 24 + 9, 25, resets: resets), weekly(3, 40, resets: resets),
        ]
        let days = try #require(LimitUsage.daily(.weekly, in: readings, days: 7, endingAt: midnight + 10 * hour, calendar: calendar))
        // Two days ago: 10 to 25. Today: 25 to 40. Every other day: nothing.
        #expect(days == [0, 0, 0, 0, 15, 0, 15])
    }

    @Test func aWeekWithoutEarlierReadingsIsUnknownNotZero() {
        let readings = [weekly(3, 40, resets: midnight + 3 * 24 * hour)]
        #expect(LimitUsage.daily(.weekly, in: readings, days: 7, endingAt: midnight + 10 * hour, calendar: calendar) == nil)
    }
}

@Suite("Usage-limit forecasts")
struct LimitForecastTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    @Test func paceComesFromReadingsInTheCurrentPeriod() throws {
        let reset = base.addingTimeInterval(3 * hour)
        let oldPeriod = reading(-3, .fiveHour, 90, resets: base)
        let readings = [oldPeriod, reading(-1, .fiveHour, 39, resets: reset), reading(0, .fiveHour, 62, resets: reset)]
        let period = LimitForecast.currentPeriod(of: .fiveHour, in: readings)
        #expect(period.count == 2)
        #expect(LimitForecast.percentPerHour(period) == 23)
    }

    @Test func paceIsUnknownFromASingleReading() {
        let period = LimitForecast.currentPeriod(of: .monthly, in: [reading(0, .monthly, 64, resets: base)])
        #expect(LimitForecast.percentPerHour(period) == nil)
    }

    @Test func runsOutWhenPaceReachesOneHundredBeforeTheReset() throws {
        // 62% at 23 points an hour reaches 100% in 99 minutes.
        let runsOut = try #require(
            LimitForecast.runsOutAt(
                usedPercent: 62, readAt: base, resetsAt: base.addingTimeInterval(2 * hour + 8 * 60), percentPerHour: 23
            )
        )
        #expect(abs(runsOut.timeIntervalSince(base) / 60 - 99.13) < 0.01)
    }

    @Test func doesNotRunOutWhenTheResetComesFirst() {
        #expect(LimitForecast.runsOutAt(
            usedPercent: 62, readAt: base, resetsAt: base.addingTimeInterval(hour), percentPerHour: 23
        ) == nil)
        #expect(LimitForecast.runsOutAt(
            usedPercent: 62, readAt: base, resetsAt: base.addingTimeInterval(hour), percentPerHour: nil
        ) == nil)
    }

    @Test func alreadyRunOutAtOneHundredPercent() {
        #expect(LimitForecast.runsOutAt(
            usedPercent: 100, readAt: base, resetsAt: base.addingTimeInterval(hour), percentPerHour: nil
        ) == base)
    }

    @Test func projectsWhatIsLeftAtTheReset() throws {
        // 48% used, 15 points a day, 66.47 hours to go: about 10.5% left.
        let left = try #require(
            LimitForecast.projectedLeftAtReset(
                usedPercent: 48, readAt: base, resetsAt: base.addingTimeInterval(66.4667 * hour),
                percentPerHour: 15.0 / 24
            )
        )
        #expect(abs(left - 10.458) < 0.001)
    }

    @Test func projectedLeftNeverGoesBelowZero() {
        #expect(LimitForecast.projectedLeftAtReset(
            usedPercent: 90, readAt: base, resetsAt: base.addingTimeInterval(10 * hour), percentPerHour: 5
        ) == 0)
    }

    @Test func sessionShareIsPaceTimesActiveTime() throws {
        // 23 points an hour over 23 active minutes is 8.8 points.
        let share = try #require(
            LimitForecast.sessionShare(percentPerHour: 23, activeDuration: 23 * 60, limitUsedPercent: 62)
        )
        #expect(abs(share - 8.8167) < 0.001)
        #expect(LimitForecast.sessionShare(percentPerHour: 23, activeDuration: 10 * hour, limitUsedPercent: 62) == 62)
        #expect(LimitForecast.sessionShare(percentPerHour: nil, activeDuration: hour, limitUsedPercent: 62) == nil)
    }

    @Test func daysLeftCountsCalendarDays() {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 14, minute: 32))!
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 9))!
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        #expect(CalendarDays.between(monday, and: thursday, calendar: calendar) == 3)
        #expect(CalendarDays.between(monday, and: october, calendar: calendar) == 10)
    }
}
