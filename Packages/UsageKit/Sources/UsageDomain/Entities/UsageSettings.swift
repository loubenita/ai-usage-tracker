import Foundation

/// The user's budgets and the baselines projections are measured against.
public struct UsageSettings: Sendable, Hashable {
    /// Nil when the user has not set one: then nothing is compared with a budget.
    public let dailyCostBudget: Decimal?
    public let dailyTokenBudget: Int?
    /// The hour the working day ends, used to project today's total.
    public let workdayEndHour: Int
    /// Above this share of the window a session's context counts as nearly full.
    public let contextNearlyFullThreshold: Double
    /// The user's three-letter labels for concerns, keyed by concern: "Image generation" is "IMG".
    public let concernLabels: [String: String]
    /// The owner's keyword table for labelling live sessions by branch or folder name.
    public let labelRules: [LabelRule]

    public init(
        dailyCostBudget: Decimal?,
        dailyTokenBudget: Int?,
        workdayEndHour: Int,
        contextNearlyFullThreshold: Double = 0.85,
        concernLabels: [String: String] = [:],
        labelRules: [LabelRule] = []
    ) {
        self.dailyCostBudget = dailyCostBudget
        self.dailyTokenBudget = dailyTokenBudget
        self.workdayEndHour = workdayEndHour
        self.contextNearlyFullThreshold = contextNearlyFullThreshold
        self.concernLabels = concernLabels
        self.labelRules = labelRules
    }
}
