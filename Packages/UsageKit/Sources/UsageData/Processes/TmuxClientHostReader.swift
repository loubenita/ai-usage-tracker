import Foundation
import UsageDomain

/// Finds which terminal app each tmux client really runs in, from the process table, when Open
/// is clicked. One tmux server can be shown in several terminals at once (Warp, Terminal, iTerm),
/// so the answer is per client: the nearest terminal above the client's process.
///
/// For Warp it also reads the tab's link, `WARP_FOCUS_URL`, but only from a client whose nearest
/// terminal is Warp. Every process inherits that variable from whatever started it, so a client
/// in a Terminal window opened from a Warp tab, or one inside a pane of a tmux server first
/// started in a Warp tab, carries the link of a tab it does not sit in.
public struct TmuxClientHostReader: Sendable {
    private let source: any ProcessSource

    public init(source: any ProcessSource = SystemProcessSource()) {
        self.source = source
    }

    /// The host of each process, by pid. A pid that is not in the process table, or when the
    /// table cannot be read, is left out. A client with no terminal above it is `.unknown`, and
    /// one inside a tmux pane is `.tmux`. Neither has a link.
    public func hosts(of pids: [Int32]) -> [Int32: TmuxClientHost] {
        guard !pids.isEmpty, let list = try? source.processList() else { return [:] }
        // Only the parent chain is used, so the time zone of the start times does not matter.
        let rows = ProcessTable.parse(list, timeZone: .current)
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var hosts: [Int32: TmuxClientHost] = [:]
        for pid in pids {
            guard let row = byPID[pid] else { continue }
            let terminal = TerminalAgentFinder.terminal(in: TerminalAgentFinder.ancestors(of: row, in: byPID))
            let link = terminal == .warp
                ? WarpFocusLink.validated(source.environmentValue(WarpFocusLink.variable, of: pid))
                : nil
            hosts[pid] = TmuxClientHost(terminal: terminal, warpFocusURL: link)
        }
        return hosts
    }
}
