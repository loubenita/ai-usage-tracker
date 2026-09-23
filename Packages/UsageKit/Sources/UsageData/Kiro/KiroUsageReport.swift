import Foundation
import UsageDomain

/// Reads the plan out of what `kiro-cli chat --no-interactive "/usage"` prints.
///
/// Kiro keeps the plan's credits on its servers, so this is the only place they can be read.
/// The patterns follow CodexBar's Kiro reader (github.com/steipete/CodexBar, MIT licence,
/// `Sources/CodexBarCore/Providers/Kiro/KiroStatusProbe.swift`), which knows two layouts:
///
///     Estimated Usage | resets on 2026-10-01 | KIRO POWER      (kiro-cli 2.x)
///     Credits (2100.00 of 5000 covered in plan)
///     ████████████████████ 42%
///
///     ┃                                        | KIRO FREE ┃   (earlier releases, in a box)
///     ┃ ████████████████ 100% (resets on 01/01)            ┃
///     ┃       (0.00 of 50 covered in plan)                 ┃
///
/// Kiro was not installed on the Mac this was written on, so no real output was seen.
enum KiroUsageReport {
    /// The plan, or nil when the output has neither a percentage nor credits: not signed in,
    /// a plan managed by an organisation, or a layout this does not know.
    static func plan(in output: String, readAt: Date, calendar: Calendar) -> PlanUsage? {
        let text = stripEscapes(output)
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("login required") || lowered.contains("kiro-cli login") {
            return nil
        }
        let percent = capture(#"█+\s*(\d+(?:\.\d+)?)\s*%"#, in: text).flatMap { Double($0) }
        let credits = captures(#"\(\s*([\d,]+(?:\.\d+)?)\s+of\s+([\d,]+(?:\.\d+)?)\s+covered"#, in: text)
            .flatMap { groups -> (used: Double, limit: Double)? in
                guard groups.count == 2, let used = number(groups[0]), let limit = number(groups[1]) else { return nil }
                return (used, limit)
            }
        guard let usedPercent = percent ?? credits.flatMap({ $0.limit > 0 ? $0.used / $0.limit * 100 : nil }) else {
            return nil
        }
        return PlanUsage(
            name: planName(in: text),
            creditsUsed: credits?.used,
            creditsLimit: credits?.limit,
            usedPercent: usedPercent,
            resetsAt: capture(#"resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})"#, in: text)
                .flatMap { resetDate($0, after: readAt, calendar: calendar) },
            readAt: readAt
        )
    }

    /// "KIRO POWER" from "Estimated Usage | resets on … | KIRO POWER", "| KIRO FREE" or "Plan: …".
    static func planName(in text: String) -> String? {
        let patterns = [
            #"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]*[A-Z0-9])"#,
            #"Plan:[ \t]*([^|\r\n]+?)[ \t]*(?:\||$)"#,
            #"\|[ \t]*(KIRO[ \t]+\w+)"#,
        ]
        for pattern in patterns {
            if let name = capture(pattern, in: text)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// A full date, or "MM/DD" taken as the next such day after `after`.
    static func resetDate(_ text: String, after: Date, calendar: Calendar) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        if parts.count == 3 {
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard parts.count == 2 else { return nil }
        let year = calendar.component(.year, from: after)
        for candidate in [year, year + 1] {
            if let date = calendar.date(from: DateComponents(year: candidate, month: parts[0], day: parts[1])), date > after {
                return date
            }
        }
        return nil
    }

    /// The text without the colour and cursor codes a terminal program writes.
    static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\][^\x07]*\x07"#, with: "", options: .regularExpression)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
