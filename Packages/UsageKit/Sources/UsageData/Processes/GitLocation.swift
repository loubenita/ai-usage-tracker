import Foundation

/// The git repository a folder belongs to: its name and the checked-out branch.
struct GitLocation: Sendable, Hashable {
    let repositoryName: String
    /// Nil when HEAD is detached.
    let branch: String?
}

/// Finds a folder's repository by reading `.git` directly, without running git.
/// Works for worktrees too, where `.git` is a file pointing into the main repository.
struct GitLocator: Sendable {
    /// Reads a file's text, or nil when it does not exist. Injected so tests need no disk.
    let readFile: @Sendable (String) -> String?
    /// Whether a path is a directory, or nil when nothing is there.
    let isDirectory: @Sendable (String) -> Bool?

    func locate(folder: String) -> GitLocation? {
        var current = URL(fileURLWithPath: folder).standardizedFileURL
        while true {
            let dotGit = current.appendingPathComponent(".git").path
            switch isDirectory(dotGit) {
            case true?:
                return location(gitDir: dotGit, workTree: current.path)
            case false?:
                guard let gitDir = readFile(dotGit).flatMap(Self.gitDir(fromDotGitFile:)) else { return nil }
                let absolute = gitDir.hasPrefix("/") ? gitDir : current.appendingPathComponent(gitDir).path
                return location(gitDir: absolute, workTree: current.path)
            case nil:
                let parent = current.deletingLastPathComponent()
                guard parent.path != current.path else { return nil }
                current = parent
            }
        }
    }

    private func location(gitDir: String, workTree: String) -> GitLocation {
        GitLocation(
            repositoryName: Self.repositoryName(gitDir: gitDir, workTree: workTree),
            branch: readFile(gitDir + "/HEAD").flatMap(Self.branch(fromHEAD:))
        )
    }

    /// "ref: refs/heads/feat/image-gen-v2" gives "feat/image-gen-v2"; a detached HEAD gives nil.
    static func branch(fromHEAD contents: String) -> String? {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let branch = String(line.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }

    /// A worktree's `.git` file reads "gitdir: /path/to/repo/.git/worktrees/name".
    static func gitDir(fromDotGitFile contents: String) -> String? {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// A worktree is named after its main repository, so every worktree of one repository
    /// shows the same project; an ordinary checkout is named after its own folder.
    static func repositoryName(gitDir: String, workTree: String) -> String {
        if let range = gitDir.range(of: "/.git/worktrees/") {
            return URL(fileURLWithPath: String(gitDir[..<range.lowerBound])).lastPathComponent
        }
        return URL(fileURLWithPath: workTree).lastPathComponent
    }
}
