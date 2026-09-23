import Foundation
import UsageDomain

/// Counts what a session did as its lines are read: each tool call once by its id, each file
/// an editing tool touched once by its path, and the person's first message.
struct SessionActivityCounter: Sendable, Hashable {
    private var toolCallIDs: Set<String> = []
    private var files: Set<String> = []
    var firstAsk: String?

    mutating func called(_ id: String, editing file: String?) {
        toolCallIDs.insert(id)
        if let file { files.insert(file) }
    }

    /// Nil until the session called a tool or the person wrote something.
    var activity: SessionActivity? {
        guard !toolCallIDs.isEmpty || !files.isEmpty || firstAsk != nil else { return nil }
        return SessionActivity(
            toolCalls: toolCallIDs.isEmpty ? nil : toolCallIDs.count,
            filesChanged: files.isEmpty ? nil : files.count,
            firstAsk: firstAsk
        )
    }

    /// A message as the person's ask: its first line, without the wrappers agents put around
    /// commands and notices. Nil when nothing of the person's is left.
    static func ask(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "<command-name>", "<local-command-stdout>", "<environment_context>" and the like are
        // written by the agent, not typed.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(200))
    }
}
