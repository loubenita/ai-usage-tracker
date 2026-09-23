/// How full a session's context window is: the `context` object of a turn.
public struct ContextUsage: Sendable, Hashable {
    public let used: Int
    public let window: Int

    public init(used: Int, window: Int) {
        self.used = used
        self.window = window
    }

    /// Share of the window in use, from 0 to 1.
    public var fraction: Double {
        guard window > 0 else { return 0 }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    public var remaining: Int { max(window - used, 0) }
}
