/// Token counts of one or more turns. A nil field means the agent did not report it,
/// which is different from zero.
public struct TokenUsage: Sendable, Hashable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var reasoning: Int?

    public init(
        input: Int? = nil,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil,
        reasoning: Int? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    /// Sum of every reported field, or nil when no field was reported.
    public var total: Int? {
        let reported = [input, output, cacheRead, cacheWrite, reasoning].compactMap { $0 }
        return reported.isEmpty ? nil : reported.reduce(0, +)
    }

    /// Every reported field except cache reads: the tokens that measure the work itself.
    public var withoutCacheReads: Int {
        [input, output, cacheWrite, reasoning].compactMap { $0 }.reduce(0, +)
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: addReported(lhs.input, rhs.input),
            output: addReported(lhs.output, rhs.output),
            cacheRead: addReported(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: addReported(lhs.cacheWrite, rhs.cacheWrite),
            reasoning: addReported(lhs.reasoning, rhs.reasoning)
        )
    }

    /// Adds two optional usages, keeping nil only when neither side reported anything.
    public static func sum(_ lhs: TokenUsage?, _ rhs: TokenUsage?) -> TokenUsage? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case let (value?, nil), let (nil, value?): value
        case let (left?, right?): left + right
        }
    }

    private static func addReported(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        default: (lhs ?? 0) + (rhs ?? 0)
        }
    }
}
