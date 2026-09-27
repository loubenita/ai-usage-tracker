import Foundation

/// Where usage records come from. The fake repository serves made-up records today;
/// a real collector reading `usage.jsonl` can replace it without touching the views.
public protocol UsageRepository: Sendable {
    /// Everything from `start` to `end`: the open sessions and every past session's turns.
    func records(from start: Date, to end: Date) async throws -> UsageRecords
    /// The open sessions only, with their own turns and none of the history's, so the strip
    /// can be read every six seconds without copying a month of turns.
    func sessionRecords(from start: Date, to end: Date) async throws -> UsageRecords
    func settings() async throws -> UsageSettings
}

extension UsageRepository {
    /// A repository with no cheaper way just returns everything.
    public func sessionRecords(from start: Date, to end: Date) async throws -> UsageRecords {
        try await records(from: start, to: end)
    }
}

/// The current time. Injected so the fake data can pin "now" and tests can control it.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}
