/// A coding agent whose usage the overlay can show.
/// The raw value is the `agent` field of a saved record.
public enum Agent: String, Sendable, Hashable, CaseIterable, Codable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case kiro
    case antigravity
    case opencode

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .kiro: "Kiro"
        case .antigravity: "Antigravity"
        case .opencode: "opencode"
        }
    }
}
