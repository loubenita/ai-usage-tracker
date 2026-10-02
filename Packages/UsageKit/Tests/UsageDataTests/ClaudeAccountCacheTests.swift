import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// `account-N.json`, which the status line saves for each Claude account: the percentages, when
/// they were read, and the reset times when the status line's payload had them.
@Suite("Reading the account cache")
struct ClaudeAccountCacheTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// What the cache reads from one `account-2.json` holding `json`.
    func read(_ json: String) throws -> [AccountUsageSnapshot] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".claude/orchestrator/usage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try json.write(to: directory.appendingPathComponent("account-2.json"), atomically: true, encoding: .utf8)
        return ClaudeAccountCache.read(homeDirectory: root.path, files: FileAccess(), now: Self.now)
    }

    func account(_ extra: String = "", asOf: TimeInterval = 1_790_000_000) -> String {
        """
        {"config_dir":"/Users/me/.claude-work","five_hour_pct":20,"weekly_pct":100,"as_of":\(Int(asOf))\(extra)}
        """
    }

    @Test func readsTheResetTimesAsEpochSeconds() throws {
        let snapshot = try #require(try read(account(
            #","five_hour_resets_at":1790010000,"weekly_resets_at":1790400000"#
        )).first)
        #expect(snapshot.fiveHourResetsAt == Date(timeIntervalSince1970: 1_790_010_000))
        #expect(snapshot.weeklyResetsAt == Date(timeIntervalSince1970: 1_790_400_000))
        #expect(snapshot.fiveHourPercent == 20)
        #expect(snapshot.weeklyPercent == 100)
    }

    @Test func aFileWithoutResetTimesStillParses() throws {
        let snapshot = try #require(try read(account()).first)
        #expect(snapshot.fiveHourResetsAt == nil)
        #expect(snapshot.weeklyResetsAt == nil)
        #expect(snapshot.fiveHourPercent == 20)
        #expect(snapshot.weeklyPercent == 100)
    }

    @Test func eachResetTimeIsOptionalOnItsOwn() throws {
        let snapshot = try #require(try read(account(#","weekly_resets_at":1790400000"#)).first)
        #expect(snapshot.fiveHourResetsAt == nil)
        #expect(snapshot.weeklyResetsAt == Date(timeIntervalSince1970: 1_790_400_000))
    }

    @Test func aResetTimeThatIsNotAUsableNumberIsLeftOutAndThePercentagesStay() throws {
        for unusable in [#""soon""#, "true", "false", "0", "-5", "null", "[]", #"{"at":1}"#] {
            let snapshot = try #require(try read(account(
                #","five_hour_resets_at":\#(unusable),"weekly_resets_at":\#(unusable)"#
            )).first, "\(unusable)")
            #expect(snapshot.fiveHourResetsAt == nil, "\(unusable)")
            #expect(snapshot.weeklyResetsAt == nil, "\(unusable)")
            #expect(snapshot.fiveHourPercent == 20, "\(unusable)")
            #expect(snapshot.weeklyPercent == 100, "\(unusable)")
        }
    }

    @Test func aReadingIsAcceptedForUpToSevenDays() throws {
        let day: TimeInterval = 86_400
        #expect(try read(account(asOf: Self.now.timeIntervalSince1970 - 6 * day)).count == 1)
        #expect(try read(account(asOf: Self.now.timeIntervalSince1970 - 8 * day)).isEmpty)
        // A reading from the future is not a reading.
        #expect(try read(account(asOf: Self.now.timeIntervalSince1970 + 60)).isEmpty)
    }
}
