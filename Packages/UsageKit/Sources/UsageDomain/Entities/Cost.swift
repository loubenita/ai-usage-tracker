import Foundation

/// How `Cost.usd` was arrived at: the `cost.basis` field of a record.
public enum CostBasis: String, Sendable, Hashable {
    case apiListPrice = "api-list-price"
    case bill
    case credits
}

/// The `cost` object of a record. `usd` is nil when the agent reported no price.
public struct Cost: Sendable, Hashable {
    public let usd: Decimal?
    public let basis: CostBasis
    public let credits: Int?

    public init(usd: Decimal?, basis: CostBasis = .apiListPrice, credits: Int? = nil) {
        self.usd = usd
        self.basis = basis
        self.credits = credits
    }
}
