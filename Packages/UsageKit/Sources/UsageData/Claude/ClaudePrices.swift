import Foundation
import UsageDomain

/// Anthropic's list prices per million tokens, from the Claude API reference as cached on
/// 24 June 2026. Update this table when prices change.
enum ClaudePrices {
    static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: Decimal(string: "0.25")!, contextWindow: 1_000_000)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1, contextWindow: 1_000_000)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: Decimal(string: "0.5")!, contextWindow: 1_000_000)),
        ("claude-opus-4", ModelPrice(input: 5, output: 25, cacheRead: Decimal(string: "0.5")!, contextWindow: 1_000_000)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: Decimal(string: "0.2")!, contextWindow: 1_000_000)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: Decimal(string: "0.3")!, contextWindow: 1_000_000)),
        ("claude-haiku-4", ModelPrice(input: 1, output: 5, cacheRead: Decimal(string: "0.1")!, contextWindow: 200_000)),
    ]

    /// The price for a model id such as "claude-opus-5", or nil for a model not in the table
    /// (its cost is then shown as not reported rather than guessed).
    static func price(for model: String) -> ModelPrice? {
        table.first { model.hasPrefix($0.prefix) }?.price
    }
}
