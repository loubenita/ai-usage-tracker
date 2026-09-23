import Foundation
import Testing
@testable import UsageDomain

private let minute: TimeInterval = 60
private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let tag = WorkTag(project: "Marketing Studio", concern: "Image generation")

private func event(_ kind: SessionEvent.Kind, _ state: SessionState, at offset: TimeInterval,
                   active: TimeInterval, idle: TimeInterval, id: String = "s1") -> SessionEvent {
    SessionEvent(
        timestamp: start.addingTimeInterval(offset), agent: .claudeCode, sessionID: id, kind: kind,
        state: state, activeDuration: active, idleDuration: idle, work: tag
    )
}

@Suite("Session summaries")
struct SessionSummariesTests {
    @Test func waitingSessionCountsIdleTimeNotActiveTime() throws {
        let events = [
            event(.start, .working, at: 0, active: 0, idle: 0),
            event(.idle, .waiting, at: 23 * minute, active: 23 * minute, idle: 0),
        ]
        let now = start.addingTimeInterval(27 * minute)
        let summary = try #require(SessionSummaries.make(turns: [], events: events, now: now).first)
        #expect(summary.activeDuration == 23 * minute)
        #expect(summary.idleDuration == 4 * minute)
        #expect(summary.needsUser)
    }

    @Test func workingSessionKeepsCountingActiveTime() throws {
        let events = [
            event(.start, .working, at: 0, active: 0, idle: 0),
            event(.active, .working, at: 60 * minute, active: 51 * minute, idle: 9 * minute),
        ]
        let summary = try #require(
            SessionSummaries.make(turns: [], events: events, now: start.addingTimeInterval(67 * minute)).first
        )
        #expect(summary.activeDuration == 58 * minute)
        #expect(summary.idleDuration == 9 * minute)
    }

    @Test func totalsComeFromTheSessionsTurnsAndContextFromTheLatest() throws {
        func turn(_ offset: TimeInterval, cost: String, context: Int) -> Turn {
            Turn(
                id: "t\(offset)", timestamp: start.addingTimeInterval(offset), agent: .claudeCode, sessionID: "s1",
                model: "claude-opus-5", work: Work(tag: tag, branch: "feat/x"),
                tokens: TokenUsage(input: 10, output: 5), cost: Cost(usd: Decimal(string: cost)),
                context: ContextUsage(used: context, window: 200_000)
            )
        }
        let summary = try #require(
            SessionSummaries.make(
                turns: [turn(120, cost: "0.25", context: 60_000), turn(60, cost: "0.75", context: 30_000)],
                events: [event(.start, .working, at: 0, active: 0, idle: 0)],
                now: start.addingTimeInterval(300)
            ).first
        )
        #expect(summary.turnCount == 2)
        #expect(summary.tokens?.total == 30)
        #expect(summary.costUSD == 1)
        #expect(summary.context?.used == 60_000)
        #expect(summary.work.branch == "feat/x")
    }

    @Test func keepsTheOrderSessionsFirstAppearIn() {
        let events = [
            event(.start, .working, at: 0, active: 0, idle: 0, id: "b"),
            event(.start, .working, at: -60, active: 0, idle: 0, id: "a"),
        ]
        #expect(SessionSummaries.make(turns: [], events: events, now: start).map(\.id) == ["b", "a"])
    }

    @Test func endedSessionsAreMarkedEnded() throws {
        let events = [
            event(.start, .working, at: 0, active: 0, idle: 0),
            event(.end, .idle, at: 60, active: 60, idle: 0),
        ]
        let summary = try #require(SessionSummaries.make(turns: [], events: events, now: start.addingTimeInterval(600)).first)
        #expect(summary.state == .ended)
        #expect(summary.activeDuration == 60)
    }
}
