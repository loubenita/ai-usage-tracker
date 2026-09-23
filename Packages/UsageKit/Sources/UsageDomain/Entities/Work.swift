/// What a session is working on: the `work.project` and `work.concern` of a record.
/// Sessions with the same tag are grouped together in the Today and This week tabs.
public struct WorkTag: Sendable, Hashable {
    public let project: String
    public let concern: String

    public init(project: String, concern: String) {
        self.project = project
        self.concern = concern
    }

    /// "Marketing Studio" becomes "MS"; a one-word project keeps its name ("OpenKitchen").
    public var projectShortName: String {
        let words = project.split(separator: " ")
        guard words.count > 1 else { return project }
        return String(words.compactMap(\.first)).uppercased()
    }

    /// The three-letter label inside a session's ring. The user's own label wins
    /// ("Image generation" is "IMG"); otherwise the first three letters: "Video generation" is "VID".
    public func concernCode(labels: [String: String] = [:]) -> String {
        if let label = labels[concern] { return label }
        let firstWord = concern.split(separator: " ").first.map(String.init) ?? concern
        return String(firstWord.prefix(3)).uppercased()
    }
}

/// The `work` object of a turn record.
public struct Work: Sendable, Hashable {
    public let tag: WorkTag
    public let taggedBy: String?
    public let repoRemote: String?
    public let branch: String?
    public let folder: String?

    public init(
        tag: WorkTag,
        taggedBy: String? = nil,
        repoRemote: String? = nil,
        branch: String? = nil,
        folder: String? = nil
    ) {
        self.tag = tag
        self.taggedBy = taggedBy
        self.repoRemote = repoRemote
        self.branch = branch
        self.folder = folder
    }
}
