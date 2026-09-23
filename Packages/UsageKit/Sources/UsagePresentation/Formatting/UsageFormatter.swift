import Foundation

/// Turns numbers into the short text the overlay shows. Every rule the design uses lives here:
/// whole percentages, "280k" and "1.2M" tokens, "h:mm" timers, 24-hour clock times.
public struct UsageFormatter: Sendable {
    /// Shown where an agent did not report a value. Null is not zero.
    public static let notReported = "–"

    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: - Percentages

    /// A share from 0 to 1 as a whole percentage, rounding halves up: 0.4667 is "47%".
    public func percent(_ fraction: Double?) -> String {
        guard let fraction else { return Self.notReported }
        return percentPoints(fraction * 100)
    }

    /// A value already in percent as a whole percentage: 62.0 is "62%".
    public func percentPoints(_ points: Double?) -> String {
        guard let points else { return Self.notReported }
        return "\(Int(points.rounded(.toNearestOrAwayFromZero)))%"
    }

    /// Percent rounded to the nearest 5 for "about" statements: 10.46 is "10%".
    public func approximatePercentPoints(_ points: Double) -> String {
        "\(Int((points / 5).rounded(.toNearestOrAwayFromZero)) * 5)%"
    }

    // MARK: - Tokens and money

    /// 280_000 is "280k", 1_200_000 is "1.2M", 12_200_000 is "12.2M", 2_000_000 is "2M",
    /// 2_955_900_000 is "3B".
    public func tokens(_ count: Int?) -> String {
        guard let count else { return Self.notReported }
        switch count {
        case ..<1_000:
            return "\(count)"
        case ..<999_500:
            return "\(Int((Double(count) / 1_000).rounded(.toNearestOrAwayFromZero)))k"
        case ..<999_950_000:
            return oneDecimal(Double(count) / 1_000_000, unit: "M")
        default:
            return oneDecimal(Double(count) / 1_000_000_000, unit: "B")
        }
    }

    /// Tokens for a ring, where there is room for three characters and a unit: 940, "79k",
    /// "1.1M", "46M", "444M", "1.2B", "24B". Rounded to the nearest, so 46.1M is "46M" and
    /// 443.8M is "444M". The panels show the fuller `tokens(_:)` instead.
    public func ringTokens(_ count: Int?) -> String {
        guard let count else { return Self.notReported }
        func whole(_ value: Double, _ unit: String) -> String {
            "\(Int(value.rounded(.toNearestOrAwayFromZero)))\(unit)"
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<999_500: return whole(Double(count) / 1_000, "k")
        case ..<9_950_000: return oneDecimal(Double(count) / 1_000_000, unit: "M")
        case ..<999_500_000: return whole(Double(count) / 1_000_000, "M")
        case ..<9_950_000_000: return oneDecimal(Double(count) / 1_000_000_000, unit: "B")
        default: return whole(Double(count) / 1_000_000_000, "B")
        }
    }

    /// Kiro credits to one decimal place: 12.43 is "12.4", 50 is "50".
    /// "1 Sep": a day of the month with its month, for the Month chart's labels.
    public func dayOfMonth(_ date: Date) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        return "\(parts.day ?? 0) \(calendar.shortMonthSymbols[(parts.month ?? 1) - 1])"
    }

    /// A plan name as Kiro writes it, in capitals, put in title case: "KIRO POWER" is "Kiro Power".
    public func planName(_ name: String) -> String {
        name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// "12.4" below a hundred, whole and grouped from there: "3,917".
    public func credits(_ value: Double) -> String {
        guard value >= 100 else { return oneDecimal(value, unit: "") }
        return grouped(value)
    }

    /// One decimal place, dropping ".0": 1.24 is "1.2", 2.96 is "3".
    private func oneDecimal(_ value: Double, unit: String) -> String {
        let tenths = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
        return tenths == tenths.rounded() ? "\(Int(tenths))\(unit)" : String(format: "%.1f\(unit)", tenths)
    }

    /// A rate rounded to the nearest 10k, because it is an estimate: 730_435 is "730k".
    public func tokenRate(_ perHour: Double) -> String {
        guard perHour < 995_000 else { return tokens(Int(perHour)) }
        let tens = Int((perHour / 10_000).rounded(.toNearestOrAwayFromZero)) * 10
        return "\(tens)k"
    }

    /// "$1.10", "$12.90".
    /// "$31.40", and from $1,000 up whole dollars, grouped: "$1,489".
    public func usd(_ amount: Decimal?) -> String {
        guard let amount else { return Self.notReported }
        let value = NSDecimalNumber(decimal: amount).doubleValue
        guard value >= 1_000 else { return "$" + String(format: "%.2f", value) }
        return "$" + grouped(value)
    }

    /// A count with commas: 1,480.
    public func grouped(_ value: Int) -> String {
        grouped(Double(value))
    }

    /// A whole number with commas: 13,787.
    private func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded(.toNearestOrAwayFromZero))) ?? "\(Int(value))"
    }

    /// A budget drops zero cents: "$9", but "$9.50".
    public func usdBudget(_ amount: Decimal) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return value == value.rounded() ? "$\(Int(value))" : usd(amount)
    }

    // MARK: - Time

    /// How long a session has run, with a unit on each part: "23m", "4h 11m", "22h 05m",
    /// "1d 3h". A plain "27:05" was read as minutes when it meant 27 hours. Minutes after hours
    /// take two digits, so a column of times lines up.
    public func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(max(interval, 0) / 60)
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes % 60) }
        return "\(minutes)m"
    }

    /// How long a session has run, short enough for the strip: "47m", "1h47", "22h45", "1d3h".
    /// The panels have room for the fuller `duration(_:)`.
    public func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(max(interval, 0) / 60)
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h" + String(format: "%02d", minutes % 60) }
        return "\(minutes)m"
    }

    /// Whole hours for a chart label: "3h", or minutes below an hour: "40m".
    public func hours(_ interval: TimeInterval) -> String {
        guard interval >= 3600 else { return "\(Int(max(interval, 0) / 60))m" }
        return "\(Int((interval / 3600).rounded(.toNearestOrAwayFromZero)))h"
    }

    /// When something happens, as short as the distance allows: "16:40" today, "Thu 09:00"
    /// later, "1 Oct" at a midnight.
    public func moment(_ date: Date, now: Date) -> String {
        calendar.isDate(date, inSameDayAs: now) ? clock(date) : resetMoment(date)
    }

    /// A column's short reset: "16:40" today, "Thu" this week, "1 Oct" further off.
    public func shortMoment(_ date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date) }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 { return weekday(date) }
        return dayOfMonth(date)
    }

    /// "14:32".
    public func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A forecast time rounded to the nearest five minutes: 15:16:36 is "15:15".
    public func approximateClock(_ date: Date) -> String {
        let fiveMinutes: TimeInterval = 300
        let startOfDay = calendar.startOfDay(for: date)
        let offset = date.timeIntervalSince(startOfDay)
        let rounded = (offset / fiveMinutes).rounded(.toNearestOrAwayFromZero) * fiveMinutes
        return clock(startOfDay.addingTimeInterval(rounded))
    }

    /// The month's full name: "September".
    public func monthName(_ date: Date) -> String {
        calendar.monthSymbols[calendar.component(.month, from: date) - 1]
    }

    /// Short weekday: "Tue".
    public func weekday(_ date: Date) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols[calendar.component(.weekday, from: date) - 1]
    }

    /// When a limit resets: "Thu 09:00", or "1 Oct" when it resets at midnight.
    public func resetMoment(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .day, .month], from: date)
        if parts.hour == 0 && parts.minute == 0 {
            let month = calendar.shortMonthSymbols[(parts.month ?? 1) - 1]
            return "\(parts.day ?? 0) \(month)"
        }
        return "\(weekday(date)) \(clock(date))"
    }

    /// "1 day left", "3 days left".
    public func daysLeft(_ days: Int) -> String {
        days == 1 ? "1 day left" : "\(days) days left"
    }

    // MARK: - Places

    /// A folder with the home directory shortened: "/Users/me/wt/app" is "~/wt/app".
    public func folder(_ path: String?) -> String {
        guard let path else { return Self.notReported }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    // MARK: - Pace

    /// "1.3× your usual", or "about your usual" within a tenth of it.
    public func timesUsual(_ ratio: Double) -> String {
        if (0.9...1.1).contains(ratio) { return "about your usual" }
        let tenths = (ratio * 10).rounded(.toNearestOrAwayFromZero) / 10
        let number = tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
        return "\(number)× your usual"
    }

    /// How a rate compares with the usual one, in words.
    /// Rounded to one decimal place, so it never overstates: 1.33 is "1.3 times", 0.95 is
    /// "about your usual rate", and "twice" only from 1.95 until it rounds to 2.1.
    public func comparedWithUsual(_ ratio: Double) -> String {
        let tenths = (ratio * 10).rounded(.toNearestOrAwayFromZero) / 10
        switch ratio {
        case 0.9...1.1: return "about your usual rate"
        case 1.95..<2.05: return "twice your usual rate"
        default:
            let number = tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
            return "\(number) times your usual rate"
        }
    }
}
