import Testing
@testable import UsageDomain

@Suite("A session's title in its panel")
struct TaskTitleTests {
    @Test func aNameTheSessionWasGivenWins() {
        let source = LabelSource(sessionName: "lead", branch: "feat/session-detection", folderName: "ai-usage-tracker")
        #expect(TaskTitle.make(source) == "lead")
    }

    @Test func aTaskBranchLosesItsPrefixAndDashes() {
        #expect(TaskTitle.make(LabelSource(branch: "feat/session-detection", folderName: "x")) == "Session detection")
        #expect(TaskTitle.make(LabelSource(branch: "feat/image-gen-v2", folderName: "x")) == "Image gen v2")
        #expect(TaskTitle.make(LabelSource(branch: "users/me/fix_login_crash", folderName: "x")) == "Fix login crash")
        #expect(TaskTitle.make(LabelSource(branch: "PROJ-60-fixer", folderName: "x")) == "PROJ 60 fixer")
    }

    @Test func otherwiseTheFolderName() {
        #expect(TaskTitle.make(LabelSource(branch: "main", folderName: "ai-usage-tracker")) == "ai-usage-tracker")
        #expect(TaskTitle.make(LabelSource(branch: nil, folderName: "me")) == "me")
        #expect(TaskTitle.make(LabelSource(sessionName: "  ", branch: "HEAD", folderName: "tracker")) == "tracker")
    }
}
