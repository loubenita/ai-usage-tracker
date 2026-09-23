import Foundation

/// A model's list price in US dollars per million tokens, and its context window.
/// Cache writes cost 1.25 times the input price for the 5-minute cache and twice it for the
/// 1-hour cache.
public struct ModelPrice: Sendable, Hashable {
    public let input: Decimal
    public let output: Decimal
    public let cacheRead: Decimal
    public let contextWindow: Int

    public init(input: Decimal, output: Decimal, cacheRead: Decimal, contextWindow: Int) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.contextWindow = contextWindow
    }

    /// The cost of one model reply.
    public func cost(input: Int, output: Int, cacheRead: Int, cacheWriteFiveMinute: Int, cacheWriteOneHour: Int) -> Decimal {
        let perMillion = Decimal(1_000_000)
        let dollars = Decimal(input) * self.input
            + Decimal(output) * self.output
            + Decimal(cacheRead) * self.cacheRead
            + Decimal(cacheWriteFiveMinute) * self.input * Decimal(string: "1.25")!
            + Decimal(cacheWriteOneHour) * self.input * 2
        return dollars / perMillion
    }
}
