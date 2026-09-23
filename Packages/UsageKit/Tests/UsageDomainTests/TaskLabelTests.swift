import Foundation
import Testing
@testable import UsageDomain

@Suite("Ring labels for live sessions")
struct TaskLabelTests {
    let rules = [LabelRule("video", "VID"), LabelRule("bug", "BUG"), LabelRule("fix", "BUG")]

    @Test func takesTheFirstWordOfATaskBranch() {
        #expect(TaskLabel.make(branch: "feat/image-gen-v2", folderName: "marketing-studio", rules: []) == "IMAG")
        #expect(TaskLabel.make(branch: "session-detection", folderName: "x", rules: []) == "SESS")
    }

    @Test func theRuleTableTurnsImageIntoIMG() {
        let rules = [LabelRule("image", "IMG")]
        #expect(TaskLabel.make(branch: "feat/image-gen-v2", folderName: "marketing-studio", rules: rules) == "IMG")
    }

    @Test func aRuleOnTheBranchWinsOverItsFirstWord() {
        #expect(TaskLabel.make(branch: "feat/render-video", folderName: "ms", rules: rules) == "VID")
        #expect(TaskLabel.make(branch: "fix/checkout-rounding", folderName: "openkitchen", rules: rules) == "BUG")
    }

    @Test func rulesIgnoreCase() {
        #expect(TaskLabel.make(branch: "feat/Video-Export", folderName: "ms", rules: rules) == "VID")
    }

    @Test func aTrunkBranchFallsBackToTheFolder() {
        #expect(TaskLabel.make(branch: "main", folderName: "ai-usage-tracker", rules: []) == "AIUT")
        #expect(TaskLabel.make(branch: "develop", folderName: "app-ios", rules: []) == "APP")
    }

    @Test func aRuleOnTheFolderAppliesWhenTheBranchSaysNothing() {
        #expect(TaskLabel.make(branch: "main", folderName: "ok-bug-fixes", rules: rules) == "BUG")
    }

    @Test func noRepositoryUsesTheFolder() {
        #expect(TaskLabel.make(branch: nil, folderName: "tracker", rules: rules) == "TRAC")
    }

    @Test func skipsPunctuationInTheFolderName() {
        #expect(TaskLabel.make(branch: nil, folderName: ".claude", rules: []) == "CLAU")
        #expect(TaskLabel.make(branch: nil, folderName: "a-b", rules: []) == "AB")
    }

    @Test func labelsAreAtMostFourCharacters() {
        #expect(TaskLabel.make(branch: "feat/architecture", folderName: "x", rules: []) == "ARCH")
        #expect(TaskLabel.make(branch: nil, folderName: "internationalisation", rules: []).count == TaskLabel.maxLength)
    }

    @Test func aTicketNumberBecomesItsCode() {
        #expect(TaskLabel.make(LabelSource(sessionName: "PROJ-60-Fixer", branch: nil, folderName: "x"), rules: rules) == "PR60")
        #expect(TaskLabel.make(branch: "proj-60/closedStream", folderName: "acme", rules: []) == "PR60")
        #expect(TaskLabel.make(branch: "OK-7-rounding", folderName: "x", rules: []) == "OK7")
        #expect(TaskLabel.make(branch: "PROJ-1234", folderName: "x", rules: []) == "P123")
    }

    @Test func aNameThePersonGaveWinsOverBranchAndFolder() {
        let lead = LabelSource(sessionName: "lead", branch: nil, folderName: "me", isHomeFolder: true)
        #expect(TaskLabel.make(lead, rules: rules) == "LEAD")
        let named = LabelSource(sessionName: "ai-usage-tracker", branch: "feat/session-detection", folderName: "x")
        #expect(TaskLabel.make(named, rules: []) == "AIUT")
    }

    @Test func theRuleTableAppliesToTheSessionNameToo() {
        let source = LabelSource(sessionName: "video-export", branch: "main", folderName: "ms")
        #expect(TaskLabel.make(source, rules: rules) == "VID")
    }

    @Test func theHomeFolderIsHOMENotTheUsersName() {
        let home = LabelSource(branch: nil, folderName: "me", isHomeFolder: true)
        #expect(TaskLabel.make(home, rules: []) == "HOME")
    }

    @Test func kindOfChangeWordsAndCamelCaseAreSkippedAndSplit() {
        #expect(TaskLabel.make(branch: "chore/architectureLint", folderName: "x", rules: []) == "ARCH")
        #expect(TaskLabel.make(branch: "feature/checkout", folderName: "x", rules: []) == "CHEC")
        #expect(TaskLabel.words(in: "chore/architectureLint") == ["architecture", "Lint"])
    }

    @Test func aBranchWithNoWordsFallsBackToTheFolder() {
        #expect(TaskLabel.make(branch: "v2/1.0", folderName: "tracker", rules: []) == "TRAC")
    }
}
