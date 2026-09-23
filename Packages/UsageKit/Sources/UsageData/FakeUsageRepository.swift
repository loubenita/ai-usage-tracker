import Foundation
import UsageDomain

/// Serves made-up records that reproduce the numbers in the Paper design.
/// A real collector reading `usage.jsonl` replaces this type; nothing else changes.
public struct FakeUsageRepository: UsageRepository {
    private let data: FakeUsageData
    private let sessionCount: Int?

    /// - Parameter sessionCount: how many sessions to show, to test a short or a long strip.
    ///   Nil shows the design's three. Fewer keeps the first ones; more adds working sessions
    ///   with no usage yet.
    public init(calendar: Calendar = .current, sessionCount: Int? = nil) {
        self.data = FakeUsageData(calendar: calendar)
        self.sessionCount = sessionCount.map { max($0, 0) }
    }

    /// The moment the fake data describes: Monday 21 September 2026, 14:32 local time.
    public var anchor: Date { data.now }

    public func records(from start: Date, to end: Date) async throws -> UsageRecords {
        let all = data.records()
        let inRange = { (date: Date) in date >= start && date <= end }
        return UsageRecords(
            turns: all.turns.filter { inRange($0.timestamp) },
            limits: all.limits.filter { inRange($0.timestamp) },
            sessionEvents: sized(all.sessionEvents).filter { inRange($0.timestamp) },
            capturedAt: all.capturedAt,
            usualRates: all.usualRates
        )
    }

    private static let extraConcerns = [
        "Onboarding flow", "Search index", "Payments", "Release notes", "Docs site", "Analytics",
        "Auth tokens", "Settings screen", "Crash reports", "Widgets", "Localisation", "Push alerts",
    ]

    private func sized(_ events: [SessionEvent]) -> [SessionEvent] {
        guard let count = sessionCount else { return events }
        var ids: [String] = []
        for event in events where !ids.contains(event.sessionID) { ids.append(event.sessionID) }
        let kept = Set(ids.prefix(count))
        let extras = (0..<max(count - ids.count, 0)).map { index in
            SessionEvent(
                timestamp: data.now.addingTimeInterval(-Double(index + 1) * 11 * 60),
                agent: .claudeCode,
                sessionID: "s_extra_\(index + 1)",
                kind: .start,
                state: .working,
                activeDuration: 0,
                idleDuration: 0,
                work: WorkTag(project: "Demo", concern: Self.extraConcerns[index % Self.extraConcerns.count])
            )
        }
        return events.filter { kept.contains($0.sessionID) } + extras
    }

    public func settings() async throws -> UsageSettings {
        FakeUsageData.settings
    }
}

/// A clock that starts at the fake data's moment and then runs in real time,
/// so the timers tick while the numbers stay the ones in the design.
public struct FakeTimeSource: TimeSource {
    private let start: Date
    private let launchedAt: Date

    public init(start: Date, launchedAt: Date = Date()) {
        self.start = start
        self.launchedAt = launchedAt
    }

    public var now: Date { start.addingTimeInterval(Date().timeIntervalSince(launchedAt)) }
}
