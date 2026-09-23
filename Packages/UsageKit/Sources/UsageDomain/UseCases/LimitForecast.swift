import Foundation

/// A usage-limit window as the overlay shows it: where it stands and where it is heading.
public struct LimitReport: Sendable, Hashable {
    public let kind: LimitWindowKind
    public let usedPercent: Double
    public let resetsAt: Date
    public let readAt: Date
    /// Percentage points used per hour, measured between readings of this window.
    public let percentPerHour: Double?
    /// When the window reaches 100%, or nil when it resets first.
    public let runsOutAt: Date?
    /// Percentage of the window expected to be left when it resets.
    public let projectedLeftAtReset: Double?
    /// Calendar days until the reset: Monday to Thursday is 3.
    public let calendarDaysLeft: Int
}

public enum LimitForecast {
    /// Readings of one window kind that belong to its current period (same reset time as the latest).
    public static func currentPeriod(
        of kind: LimitWindowKind,
        in readings: [LimitReading]
    ) -> [(date: Date, window: LimitWindowReading)] {
        let all = readings
            .compactMap { reading in
                reading.windows.first { $0.kind == kind }.map { (date: reading.timestamp, window: $0) }
            }
            .sorted { $0.date < $1.date }
        guard let latest = all.last else { return [] }
        // Reset times a few seconds apart are the same window (see `LimitUsage`).
        return all.filter {
            abs($0.window.resetsAt.timeIntervalSince(latest.window.resetsAt)) <= LimitUsage.sameResetTolerance
        }
    }

    /// Percentage points per hour between the first and last reading. Nil with fewer than two.
    public static func percentPerHour(_ period: [(date: Date, window: LimitWindowReading)]) -> Double? {
        guard let first = period.first, let last = period.last else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return nil }
        return (last.window.usedPercent - first.window.usedPercent) / hours
    }

    /// When usage reaches 100% at `percentPerHour`, or nil if the window resets first.
    public static func runsOutAt(
        usedPercent: Double,
        readAt: Date,
        resetsAt: Date,
        percentPerHour: Double?
    ) -> Date? {
        guard usedPercent < 100 else { return readAt }
        guard let rate = percentPerHour, rate > 0 else { return nil }
        let date = readAt.addingTimeInterval((100 - usedPercent) / rate * 3600)
        return date < resetsAt ? date : nil
    }

    /// Percentage left at the reset if usage keeps its pace, never below zero.
    public static func projectedLeftAtReset(
        usedPercent: Double,
        readAt: Date,
        resetsAt: Date,
        percentPerHour: Double?
    ) -> Double? {
        guard let rate = percentPerHour else { return nil }
        let hours = max(resetsAt.timeIntervalSince(readAt), 0) / 3600
        return max(100 - (usedPercent + rate * hours), 0)
    }

    /// A session's share of a limit: the limit's pace times the session's active hours,
    /// never more than the limit's own usage.
    public static func sessionShare(
        percentPerHour: Double?,
        activeDuration: TimeInterval,
        limitUsedPercent: Double
    ) -> Double? {
        guard let rate = percentPerHour, rate > 0 else { return nil }
        return min(rate * activeDuration / 3600, limitUsedPercent)
    }

    public static func report(
        _ kind: LimitWindowKind,
        from readings: [LimitReading],
        calendar: Calendar
    ) -> LimitReport? {
        let period = currentPeriod(of: kind, in: readings)
        guard let latest = period.last else { return nil }
        let rate = percentPerHour(period)
        let used = latest.window.usedPercent
        let resets = latest.window.resetsAt
        return LimitReport(
            kind: kind,
            usedPercent: used,
            resetsAt: resets,
            readAt: latest.date,
            percentPerHour: rate,
            runsOutAt: runsOutAt(usedPercent: used, readAt: latest.date, resetsAt: resets, percentPerHour: rate),
            projectedLeftAtReset: projectedLeftAtReset(
                usedPercent: used, readAt: latest.date, resetsAt: resets, percentPerHour: rate
            ),
            calendarDaysLeft: CalendarDays.between(latest.date, and: resets, calendar: calendar)
        )
    }
}

/// How much of a limit window was used in a span of time, such as today, from its readings.
///
/// A window's percentage is shared by all of an agent's sessions and moves only when the agent
/// is used, so the highest reading before the span is where the span started. Each window is
/// counted on its own: one that began during the span counts from zero, so a reset never shows
/// as negative use. On 16 September Codex's weekly window went from 99% to 0% at 16:52 and
/// started again, so that day used 31 points of the old window and 73 of the new one.
///
/// The highest reading, not the latest, is used: several Codex sessions write the same window,
/// and one a minute behind reports 36% after another has reported 37%.
public enum LimitUsage {
    /// How long each window lasts, to tell whether a period began inside the span.
    public static func length(of kind: LimitWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: 5 * 3600
        case .weekly: 7 * 24 * 3600
        case .monthly: 30 * 24 * 3600
        }
    }

    /// Reset times this close belong to one window. Codex writes the same weekly reset a few
    /// seconds apart: on 17 September, anywhere from 06:56:42 to 06:57:13.
    public static let sameResetTolerance: TimeInterval = 5 * 60

    /// Percentage points of the window used from `start` to `end`. Zero when there were readings
    /// before the span but none in it; nil when the window was never read.
    public static func used(
        _ kind: LimitWindowKind, in readings: [LimitReading], from start: Date, to end: Date
    ) -> Double? {
        let points = readings
            .compactMap { reading in reading.windows.first { $0.kind == kind }.map { (date: reading.timestamp, window: $0) } }
            .filter { $0.date <= end }
        guard !points.isEmpty else { return nil }
        return periods(points).reduce(0) { total, period in
            let inSpan = period.filter { $0.date >= start }
            guard let highest = inSpan.map(\.window.usedPercent).max(), let first = inSpan.first else { return total }
            // A window that began inside the span was at zero then; one that began earlier, with
            // no reading before the span, is counted from its first reading in it.
            let windowStart = first.window.resetsAt.addingTimeInterval(-length(of: kind))
            let baseline = period.filter { $0.date < start }.map(\.window.usedPercent).max()
                ?? (windowStart >= start ? 0 : first.window.usedPercent)
            return total + max(highest - baseline, 0)
        }
    }

    /// Readings grouped into windows by reset time, oldest window first, each in time order.
    private static func periods(
        _ points: [(date: Date, window: LimitWindowReading)]
    ) -> [[(date: Date, window: LimitWindowReading)]] {
        var periods: [[(date: Date, window: LimitWindowReading)]] = []
        for point in points.sorted(by: { $0.window.resetsAt < $1.window.resetsAt }) {
            if let reset = periods.last?.last?.window.resetsAt,
               point.window.resetsAt.timeIntervalSince(reset) <= sameResetTolerance {
                periods[periods.count - 1].append(point)
            } else {
                periods.append([point])
            }
        }
        return periods.map { $0.sorted { $0.date < $1.date } }
    }

    /// Points used on each of the `days` calendar days ending with the day of `now`, oldest first.
    /// Nil unless the readings go back to the first of those days: a day before the first reading
    /// is unknown, not zero.
    public static func daily(
        _ kind: LimitWindowKind, in readings: [LimitReading], days: Int, endingAt now: Date, calendar: Calendar
    ) -> [Double]? {
        let today = calendar.startOfDay(for: now)
        guard
            let first = calendar.date(byAdding: .day, value: -(days - 1), to: today),
            let earliest = readings.filter({ $0.windows.contains { $0.kind == kind } }).map(\.timestamp).min(),
            earliest <= first
        else { return nil }
        return (0..<days).map { offset in
            let dayStart = calendar.date(byAdding: .day, value: offset, to: first) ?? first
            // A reading exactly at midnight belongs to the day it starts, not both.
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let dayEnd = min(nextDay.addingTimeInterval(-0.001), now)
            return used(kind, in: readings, from: dayStart, to: dayEnd) ?? 0
        }
    }
}

public enum CalendarDays {
    /// Whole calendar days from one date's day to the other's: Monday 14:32 to Thursday 09:00 is 3.
    public static func between(_ start: Date, and end: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: start)
        let to = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }
}
