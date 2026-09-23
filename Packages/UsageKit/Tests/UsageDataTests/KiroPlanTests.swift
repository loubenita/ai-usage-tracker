import Foundation
import Synchronization
import Testing
import UsageDomain
@testable import UsageData

/// The two `/usage` layouts below are copied from CodexBar (github.com/steipete/CodexBar, MIT
/// licence): the newer one from `Tests/CodexBarTests/KiroStatusProbeTests.swift`, the boxed one
/// from `docs/kiro.md`. Kiro was not installed on the Mac this was written on, so no real
/// output of its own was seen.
@Suite("Reading Kiro's plan from kiro-cli")
struct KiroPlanTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Tuesday 22 September 2026, 14:00 UTC.
    let now = Date(timeIntervalSince1970: 1_790_085_600)

    static let current = """
    \u{1B}[1mEstimated Usage | resets on 2026-10-01 | KIRO POWER\u{1B}[0m
    Credits (2,100.50 of 5,000 covered in plan)
    ████████████████████ 42%
    """

    static let boxed = """
    ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
    ┃                                          | KIRO FREE  ┃
    ┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
    ┃ Monthly credits:                                    ┃
    ┃ ██████████████████████████ 100% (resets on 01/01)   ┃
    ┃                  (0.00 of 50 covered in plan)       ┃
    ┃ Bonus credits:                                      ┃
    ┃ 0.00/100 credits used, expires in 88 days           ┃
    ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
    """

    @Test func readsTheCurrentLayout() throws {
        let plan = try #require(KiroUsageReport.plan(in: Self.current, readAt: now, calendar: calendar))
        #expect(plan.name == "KIRO POWER")
        #expect(plan.creditsUsed == 2_100.5)
        #expect(plan.creditsLimit == 5_000)
        #expect(plan.usedPercent == 42)
        #expect(plan.resetsAt == Date(timeIntervalSince1970: 1_790_812_800))
        #expect(plan.readAt == now)
    }

    @Test func readsTheBoxedLayoutWithAResetWithoutAYear() throws {
        let plan = try #require(KiroUsageReport.plan(in: Self.boxed, readAt: now, calendar: calendar))
        #expect(plan.name == "KIRO FREE")
        #expect(plan.usedPercent == 100)
        #expect(plan.creditsUsed == 0)
        #expect(plan.creditsLimit == 50)
        // 01/01 read in September is next January.
        #expect(plan.resetsAt == calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
    }

    @Test func creditsAloneGiveThePercentage() throws {
        let plan = try #require(KiroUsageReport.plan(
            in: "Estimated Usage | resets on 2026-10-01 | KIRO PRO\nCredits (250 of 1000 covered in plan)",
            readAt: now, calendar: calendar
        ))
        #expect(plan.usedPercent == 25)
    }

    @Test func nothingToReadIsNoPlan() {
        for output in [
            "Error: not logged in. Run kiro-cli login",
            "Plan: KIRO PRO MAX | 1 usage breakdowns",
            "",
            "Could not retrieve usage information",
        ] {
            #expect(KiroUsageReport.plan(in: output, readAt: now, calendar: calendar) == nil, "\(output)")
        }
    }

    @Test func thePlanNameComesFromAnyLayout() {
        #expect(KiroUsageReport.planName(in: "Plan: Q Developer Pro\nmore") == "Q Developer Pro")
        #expect(KiroUsageReport.planName(in: "no plan here") == nil)
    }

    // MARK: - Asking kiro-cli

    final class FakeRunner: CommandRunner {
        let replies: Mutex<[String?]>
        let calls = Mutex<[(executable: String, arguments: [String], directory: String)]>([])
        init(_ replies: [String?]) { self.replies = Mutex(replies) }
        func run(_ executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> String? {
            calls.withLock { $0.append((executable, arguments, directory)) }
            return replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
    }

    func reader(_ runner: FakeRunner, installed: Bool = true) -> KiroPlanReader {
        KiroPlanReader(
            homeDirectory: "/Users/me", directory: "/tmp/aiut-kiro-test", runner: runner, calendar: calendar,
            isExecutable: { installed && $0 == "/Users/me/.local/bin/kiro-cli" }
        )
    }

    @Test func asksKiroCliForUsageInItsOwnFolder() throws {
        let runner = FakeRunner([Self.current])
        let reader = reader(runner)
        #expect(reader.isAvailable)
        reader.ask("/Users/me/.local/bin/kiro-cli", now: now)
        let call = try #require(runner.calls.withLock { $0.first })
        #expect(call.executable == "/Users/me/.local/bin/kiro-cli")
        #expect(call.arguments == ["chat", "--no-interactive", "/usage"])
        #expect(call.directory == "/tmp/aiut-kiro-test")
        #expect(reader.current(now: now)?.usedPercent == 42)
    }

    @Test func aFailedAskKeepsTheLastPlan() {
        let runner = FakeRunner([Self.current, nil, "not logged in"])
        let reader = reader(runner)
        reader.ask("/Users/me/.local/bin/kiro-cli", now: now)
        reader.ask("/Users/me/.local/bin/kiro-cli", now: now + 400)
        reader.ask("/Users/me/.local/bin/kiro-cli", now: now + 800)
        #expect(reader.current(now: now + 801)?.usedPercent == 42)
    }

    @Test func withoutKiroCliNothingIsRun() {
        let runner = FakeRunner([Self.current])
        let reader = reader(runner, installed: false)
        #expect(!reader.isAvailable)
        #expect(reader.current(now: now) == nil)
        #expect(runner.calls.withLock { $0.isEmpty })
    }

    @Test func theRunnerReturnsOutputAndStopsAProgramThatOverruns() {
        let runner = ProcessCommandRunner()
        #expect(runner.run("/bin/echo", arguments: ["hello"], directory: "/tmp", timeout: 5) == "hello\n")
        let started = Date()
        #expect(runner.run("/bin/sleep", arguments: ["5"], directory: "/tmp", timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(runner.run("/no/such/program", arguments: [], directory: "/tmp", timeout: 1) == nil)
    }
}
