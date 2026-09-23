import Foundation

/// One line of `ps -Ao pid,ppid,tty,lstart,command`.
struct ProcessRow: Sendable, Hashable {
    let pid: Int32
    let parentPID: Int32
    /// The controlling terminal, such as "ttys004", or nil for "??" (no terminal).
    let tty: String?
    let startedAt: Date
    /// The full command line as `ps` prints it.
    let command: String

    /// The program's own name: "claude" for "/Users/me/.local/bin/claude --resume",
    /// and "zsh" for a login shell's "-zsh".
    var executableName: String { Self.baseName(arguments.first ?? "") }

    /// The command split on spaces. `ps` does not quote arguments, so a path containing a
    /// space splits too; the names the finder looks for never contain one.
    var arguments: [String] { command.split(separator: " ").map(String.init) }

    static func baseName(_ argument: String) -> String {
        let trimmed = argument.hasPrefix("-") ? String(argument.dropFirst()) : argument
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// Reads the text `ps -Ao pid,ppid,tty,lstart,command` prints.
enum ProcessTable {
    /// Rows that cannot be read are skipped rather than failing the whole table.
    /// `lstart` is local time in the C locale ("Mon Sep 21 22:00:49 2026"); the day-first
    /// order some locales print ("Mon 21 Sep 22:00:49 2026") is read too.
    static func parse(_ output: String, timeZone: TimeZone) -> [ProcessRow] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d HH:mm:ss yyyy"
        return output.split(whereSeparator: \.isNewline).compactMap { parseLine($0, formatter: formatter) }
    }

    private static func parseLine(_ line: Substring, formatter: DateFormatter) -> ProcessRow? {
        // Eight fields before the command: pid, ppid, tty and the five words of lstart.
        var fields: [Substring] = []
        var rest = line[...]
        for _ in 0..<8 {
            rest = rest.drop { $0 == " " }
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        let command = rest.drop { $0 == " " }
        guard
            let pid = Int32(fields[0]), let parentPID = Int32(fields[1]),
            let startedAt = startDate(fields[3...7].map(String.init), formatter: formatter),
            !command.isEmpty
        else { return nil } // The header line fails here, as does anything malformed.

        let tty = fields[2] == "??" ? nil : String(fields[2])
        return ProcessRow(pid: pid, parentPID: parentPID, tty: tty, startedAt: startedAt, command: String(command))
    }

    private static func startDate(_ words: [String], formatter: DateFormatter) -> Date? {
        // words: weekday, then "Sep 21" or "21 Sep", then time and year.
        let (month, day) = Int(words[1]) == nil ? (words[1], words[2]) : (words[2], words[1])
        return formatter.date(from: "\(month) \(day) \(words[3]) \(words[4])")
    }
}
