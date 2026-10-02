import Foundation

/// Credit sums this Mac has seen, bucketed into a single day and into fixed seven-day bands
/// anchored to the plan's reset day of the month. These are a local reckoning, summed from the
/// turns this Mac recorded (`turn.credits`), kept apart from the authoritative monthly figure
/// the plan reports: a session that ran on another computer, or one whose files Kiro has since
/// wiped, is not in these sums. Everything shown from here is labelled "on this Mac".
///
/// The bands run 1 to 7, 8 to 14, 15 to 21, 22 to 28, and 29 to the month's end, counted from
/// the reset day of the month. The reset day comes from the plan's `resetsAt`; without one, the
/// 1st of the month is used, so the bands fall on calendar weeks of the month.
public struct CreditBuckets: Sendable, Hashable {
    /// One seven-day band of the month: the days it covers and the credits spent in it.
    public struct Band: Sendable, Hashable, Codable {
        /// The first and last day of the month the band covers, both inclusive: 1 and 7.
        public let firstDay: Int
        public let lastDay: Int
        /// Credits spent in the band, summed from this Mac's turns.
        public let credits: Double

        public init(firstDay: Int, lastDay: Int, credits: Double) {
            self.firstDay = firstDay
            self.lastDay = lastDay
            self.credits = credits
        }
    }

    /// Credits spent on the selected single day, on this Mac.
    public let day: Double
    /// The seven-day bands of the month, in order, each with its credits on this Mac.
    public let bands: [Band]
    /// The band that holds the selected day, when it falls in one.
    public let currentBandIndex: Int?

    public init(day: Double, bands: [Band], currentBandIndex: Int?) {
        self.day = day
        self.bands = bands
        self.currentBandIndex = currentBandIndex
    }

    /// A label used wherever these sums are shown, so they are never taken for the org-wide
    /// plan total.
    public static let scopeLabel = "on this Mac"

    /// The band boundaries for a month, as day-of-month ranges, anchored to `resetDay`.
    /// `resetDay` is clamped to 1 to 28 so the first band never starts past the shortest month;
    /// 1 gives the plain calendar-week bands.
    public static func bandRanges(resetDay: Int) -> [(firstDay: Int, lastDay: Int)] {
        let anchor = min(max(resetDay, 1), 28)
        // Bands are seven days wide from the anchor: anchor, anchor+7, ... until the last one
        // runs to day 31 (the longest month; a shorter month simply has fewer days in its last
        // band). Days before the anchor belong to the previous cycle, so they are not bucketed.
        var ranges: [(Int, Int)] = []
        var first = anchor
        while first <= 31 {
            ranges.append((first, min(first + 6, 31)))
            first += 7
        }
        return ranges
    }

    /// The buckets for `turns` that carry credits, on the day of `selectedDay` and in the bands
    /// of the month `selectedDay` falls in, anchored to `resetDay`. Only credits are summed; a
    /// turn without credits is ignored.
    public static func make(
        turns: [Turn], selectedDay: Date, resetDay: Int, calendar: Calendar
    ) -> CreditBuckets {
        let ranges = bandRanges(resetDay: resetDay)
        let startOfSelected = calendar.startOfDay(for: selectedDay)
        var dayCredits = 0.0
        var bandCredits = [Double](repeating: 0, count: ranges.count)
        for turn in turns {
            guard let credits = turn.credits else { continue }
            if calendar.isDate(turn.timestamp, inSameDayAs: selectedDay) { dayCredits += credits }
            let dayOfMonth = calendar.component(.day, from: turn.timestamp)
            if let index = ranges.firstIndex(where: { dayOfMonth >= $0.firstDay && dayOfMonth <= $0.lastDay }) {
                bandCredits[index] += credits
            }
        }
        let selectedDayOfMonth = calendar.component(.day, from: startOfSelected)
        let currentBandIndex = ranges.firstIndex {
            selectedDayOfMonth >= $0.firstDay && selectedDayOfMonth <= $0.lastDay
        }
        let bands = ranges.enumerated().map { index, range in
            Band(firstDay: range.firstDay, lastDay: range.lastDay, credits: bandCredits[index])
        }
        return CreditBuckets(day: dayCredits, bands: bands, currentBandIndex: currentBandIndex)
    }

    /// The day of the month the plan resets on, from `resetsAt`; 1 when there is no reset date.
    public static func resetDay(from resetsAt: Date?, calendar: Calendar) -> Int {
        resetsAt.map { calendar.component(.day, from: $0) } ?? 1
    }
}
