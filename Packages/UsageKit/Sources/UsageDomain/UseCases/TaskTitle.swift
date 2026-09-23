import Foundation

/// The readable title of a live session in its panel: what the person would call the task.
public enum TaskTitle {
    /// In order, the first that gives a title:
    /// 1. the name the person gave the session: "lead";
    /// 2. a task branch without its prefix, with dashes as spaces: "feat/session-detection"
    ///    is "Session detection";
    /// 3. the folder name: "ai-usage-tracker".
    public static func make(_ source: LabelSource) -> String {
        if let name = source.sessionName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        if let branch = source.branch, !TaskLabel.trunkBranches.contains(branch),
           let title = readable(branch) {
            return title
        }
        return source.folderName
    }

    /// "feat/image-gen-v2" becomes "Image gen v2"; nil when nothing is left.
    static func readable(_ branch: String) -> String? {
        let task = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = task.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        guard let first = words.first else { return nil }
        return first.uppercased() + words.dropFirst()
    }
}
