import Foundation

/// One line of the owner's label table: a session name, branch or folder name containing
/// `keyword` gets `label` in its ring. Matching ignores case.
public struct LabelRule: Sendable, Hashable {
    public let keyword: String
    public let label: String

    public init(_ keyword: String, _ label: String) {
        self.keyword = keyword
        self.label = label
    }
}

/// What a live session's label is worked out from.
public struct LabelSource: Sendable, Hashable {
    /// A name the person gave the session, such as Claude Code's `--name lead`.
    public let sessionName: String?
    public let branch: String?
    public let folderName: String
    /// The session runs in the home folder, whose name is just the user's name.
    public let isHomeFolder: Bool

    public init(sessionName: String? = nil, branch: String?, folderName: String, isHomeFolder: Bool = false) {
        self.sessionName = sessionName
        self.branch = branch
        self.folderName = folderName
        self.isHomeFolder = isHomeFolder
    }
}

/// The three-letter label inside a session's ring, worked out from where the session runs.
public enum TaskLabel {
    /// Branches that say nothing about the task, so the folder name is used instead.
    static let trunkBranches: Set<String> = ["main", "master", "develop", "dev", "trunk", "HEAD"]
    /// Branch prefixes that name the kind of change, not the task: "feat/" in "feat/image-gen".
    static let kindWords: Set<String> = ["feat", "feature", "chore", "wip", "task", "users", "user"]
    static let homeLabel = "HOME"
    /// Labels are up to four characters; the ring shrinks the text to fit.
    public static let maxLength = 4

    /// In order, the first that gives a label:
    /// 1. a ticket number in the session name or branch: "PROJ-60-Fixer" is FL60;
    /// 2. the rule table, tried on the session name, then the branch, then the folder name;
    /// 3. the name the person gave the session: "lead" is LEAD, "ai-usage-tracker" AIUT;
    /// 4. a task branch: "feat/image-gen-v2" is IMAG, "chore/architectureLint" ARCH;
    /// 5. HOME for the home folder, otherwise the folder's first word.
    public static func make(_ source: LabelSource, rules: [LabelRule]) -> String {
        let branch = source.branch.flatMap { trunkBranches.contains($0) ? nil : $0 }
        let spoken = [source.sessionName, branch].compactMap { $0 }
        for name in spoken {
            if let ticket = ticketCode(in: name) { return ticket }
        }
        for name in spoken + [source.folderName] {
            if let label = firstMatch(in: name, rules: rules) { return label }
        }
        for name in spoken {
            if let label = wordCode(name) { return label }
        }
        if source.isHomeFolder { return homeLabel }
        return wordCode(source.folderName) ?? code(source.folderName)
    }

    /// Kept for sessions known only by branch and folder.
    public static func make(branch: String?, folderName: String, rules: [LabelRule]) -> String {
        make(LabelSource(branch: branch, folderName: folderName), rules: rules)
    }

    private static func firstMatch(in name: String, rules: [LabelRule]) -> String? {
        rules.first { name.localizedCaseInsensitiveContains($0.keyword) }?.label
    }

    /// The first word, or when it is a short one like "ai", that word followed by the first
    /// letter of each word after it: "architectureLint" gives ARCH, "ai-usage-tracker" AIUT.
    private static func wordCode(_ name: String) -> String? {
        let words = words(in: name)
        guard let first = words.first else { return nil }
        guard first.count <= 2, words.count > 1 else { return code(first) }
        return code(first + words.dropFirst().compactMap(\.first).map(String.init).joined())
    }

    /// A project key and number in four characters, keeping the whole number where it fits:
    /// "PROJ-60" gives FL60, "OK-7" gives OK7, "PROJ-1234" gives P123.
    static func ticketCode(in name: String) -> String? {
        guard let match = name.firstMatch(of: /(?i)\b([a-z]+)-(\d+)\b/) else { return nil }
        let digits = String(match.2.prefix(maxLength - 1))
        let letters = match.1.prefix(max(maxLength - digits.count, 1)).uppercased()
        return letters + digits
    }

    /// Words of two letters or more, leaving out kind-of-change prefixes and splitting
    /// camelCase: "chore/architectureLint" gives ["architecture", "Lint"].
    static func words(in name: String) -> [String] {
        var words: [String] = []
        for part in name.split(whereSeparator: { !$0.isLetter }) {
            var current = ""
            for character in part {
                if character.isUppercase, let last = current.last, last.isLowercase {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            words.append(current)
        }
        return words.filter { $0.count >= 2 && !kindWords.contains($0.lowercased()) }
    }

    private static func code(_ name: String) -> String {
        let letters = name.filter { $0.isLetter || $0.isNumber }
        return String((letters.isEmpty ? name : letters).prefix(maxLength)).uppercased()
    }
}
