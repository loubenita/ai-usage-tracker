import Foundation
import Testing
@testable import UsagePresentation

@Suite("Formatting")
struct UsageFormatterTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    var format: UsageFormatter { UsageFormatter(calendar: calendar) }

    func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func percentagesRoundHalvesUp() {
        #expect(format.percent(0.46667) == "47%")
        #expect(format.percent(0.46154) == "46%")
        #expect(format.percent(0.26190) == "26%")
        #expect(format.percent(0.23810) == "24%")
        #expect(format.percent(0.125) == "13%")
        #expect(format.percent(nil) == "–")
        #expect(format.percentPoints(62) == "62%")
        #expect(format.percentPoints(8.8167) == "9%")
        #expect(format.approximatePercentPoints(10.458) == "10%")
        #expect(format.approximatePercentPoints(12.6) == "15%")
    }

    @Test func tokens() {
        #expect(format.tokens(280_000) == "280k")
        #expect(format.tokens(68_000) == "68k")
        #expect(format.tokens(1_200_000) == "1.2M")
        #expect(format.tokens(12_200_000) == "12.2M")
        #expect(format.tokens(2_911_304) == "2.9M")
        #expect(format.tokens(2_000_000) == "2M")
        #expect(format.tokens(999_700) == "1M")
        #expect(format.tokens(640) == "640")
        // A week of real use runs into billions: "2955.9M" is hard to read.
        #expect(format.tokens(2_955_900_000) == "3B")
        #expect(format.tokens(1_424_374_986) == "1.4B")
        #expect(format.tokens(999_940_000) == "999.9M")
        #expect(format.tokens(999_950_000) == "1B")
        #expect(format.tokenRate(183_100_000) == "183.1M")
        #expect(format.tokens(nil) == "–")
        #expect(format.tokenRate(730_434.78) == "730k")
        #expect(format.tokenRate(313_043.48) == "310k")
    }

    @Test func money() {
        #expect(format.usd(Decimal(string: "1.1")!) == "$1.10")
        #expect(format.usd(Decimal(string: "31.40")!) == "$31.40")
        #expect(format.usd(nil) == "–")
        // From $1,000 up, whole dollars, grouped, so a month's spend fits its column.
        #expect(format.usd(Decimal(string: "1489.40")!) == "$1,489")
        #expect(format.usd(Decimal(string: "13786.73")!) == "$13,787")
        #expect(format.usd(Decimal(string: "999.99")!) == "$999.99")
        #expect(format.usdBudget(9) == "$9")
        #expect(format.usdBudget(Decimal(string: "9.5")!) == "$9.50")
    }

    @Test func credits() {
        #expect(format.credits(12.43) == "12.4")
        #expect(format.credits(0.75) == "0.8")
        #expect(format.credits(3) == "3")
        // A hundred or more is counted in whole credits, grouped: Kiro's plans run to thousands.
        #expect(format.credits(3_917.4) == "3,917")
        #expect(format.credits(137.6) == "138")
    }

    @Test func tokensInARing() {
        // Never more than three characters and a unit, and no decimals above ten.
        #expect(format.ringTokens(940) == "940")
        #expect(format.ringTokens(999) == "999")
        #expect(format.ringTokens(1_000) == "1k")
        #expect(format.ringTokens(79_000) == "79k")
        #expect(format.ringTokens(9_949) == "10k")
        #expect(format.ringTokens(440_000) == "440k")
        #expect(format.ringTokens(1_100_000) == "1.1M")
        #expect(format.ringTokens(9_400_000) == "9.4M")
        #expect(format.ringTokens(10_000_000) == "10M")
        #expect(format.ringTokens(46_100_000) == "46M")
        #expect(format.ringTokens(443_800_000) == "444M")
        #expect(format.ringTokens(999_500_000) == "1B")
        #expect(format.ringTokens(1_000_000_000) == "1B")
        #expect(format.ringTokens(1_240_000_000) == "1.2B")
        #expect(format.ringTokens(24_000_000_000) == "24B")
        #expect(format.ringTokens(nil) == "–")
    }

    @Test func times() {
        // Units on every part, so 27 hours is never read as 27 minutes.
        #expect(format.duration(107 * 60 + 59) == "1h 47m")
        #expect(format.duration(23 * 60) == "23m")
        #expect(format.duration(4 * 3600) == "4h 00m")
        #expect(format.duration(22 * 3600 + 5 * 60) == "22h 05m")
        // The strip's shorter form.
        #expect(format.compactDuration(47 * 60) == "47m")
        #expect(format.compactDuration(107 * 60) == "1h47")
        #expect(format.compactDuration(22 * 3600 + 45 * 60) == "22h45")
        #expect(format.compactDuration(27 * 3600 + 5 * 60) == "1d3h")
        #expect(format.compactDuration(-5) == "0m")
        #expect(format.hours(3 * 3600 + 20 * 60) == "3h")
        #expect(format.hours(30 * 60) == "30m")
        #expect(format.timesUsual(1.33) == "1.3× your usual")
        #expect(format.timesUsual(2) == "2× your usual")
        #expect(format.timesUsual(1.05) == "about your usual")
        #expect(format.duration(27 * 3600 + 5 * 60) == "1d 3h")
        #expect(format.duration(24 * 3600 + 59 * 60) == "1d 0h")
        #expect(format.duration(-5) == "0m")
        #expect(format.clock(date(21, 14, 32)) == "14:32")
        #expect(format.approximateClock(date(21, 15, 16, 39)) == "15:15")
        #expect(format.approximateClock(date(21, 16, 11, 8)) == "16:10")
        #expect(format.approximateClock(date(21, 16, 12, 31)) == "16:15")
        #expect(format.weekday(date(22, 10, 0)) == "Tue")
        #expect(format.resetMoment(date(24, 9, 0)) == "Thu 09:00")
        #expect(format.resetMoment(date(1, 0, 0, month: 10)) == "1 Oct")
        #expect(format.daysLeft(3) == "3 days left")
        #expect(format.daysLeft(1) == "1 day left")
    }

    @Test func folders() {
        #expect(format.folder("/Users/me/wt/ms-image-gen") == "~/wt/ms-image-gen")
        #expect(format.folder("/opt/work") == "/opt/work")
        #expect(format.folder(nil) == "–")
    }

    @Test func paceInWords() {
        #expect(format.comparedWithUsual(1.33) == "1.3 times your usual rate")
        #expect(format.comparedWithUsual(0.95) == "about your usual rate")
        #expect(format.comparedWithUsual(1.97) == "twice your usual rate")
        #expect(format.comparedWithUsual(0.5) == "0.5 times your usual rate")
        // The edges: 0.9 and 1.1 are still about usual; 1.94 is not yet twice; 2.05 is past it.
        #expect(format.comparedWithUsual(0.9) == "about your usual rate")
        #expect(format.comparedWithUsual(1.1) == "about your usual rate")
        #expect(format.comparedWithUsual(1.12) == "1.1 times your usual rate")
        #expect(format.comparedWithUsual(1.94) == "1.9 times your usual rate")
        #expect(format.comparedWithUsual(2.05) == "2.1 times your usual rate")
        #expect(format.comparedWithUsual(3.02) == "3 times your usual rate")
    }
}
