import AppKit
import SwiftUI
import Testing
import UsageDomain
@testable import UsagePresentation

@Suite("Provider mark resources")
struct AgentMarkAssetTests {
    @Test func everyKnownAgentHasALoadableMarkInEachAppearance() {
        for agent in Agent.allCases {
            for colorScheme in [ColorScheme.light, .dark] {
                let url = AgentMarkAsset.resourceURL(for: agent, colorScheme: colorScheme)
                #expect(url != nil, "Missing resource for \(agent.rawValue) in \(colorScheme)")
                #expect(
                    url.flatMap(NSImage.init(contentsOf:)) != nil,
                    "Unreadable resource for \(agent.rawValue) in \(colorScheme)"
                )
            }
        }
    }

    @Test func cursorUsesTheProviderSuppliedAppearanceVariant() {
        #expect(AgentMarkAsset.resourceName(for: .cursor, colorScheme: .light) == "cursor-light")
        #expect(AgentMarkAsset.resourceName(for: .cursor, colorScheme: .dark) == "cursor-dark")
    }

    @Test func monochromeMarksUseTheirExistingProviderColour() {
        #expect(AgentMarkAsset.isTemplate(.claudeCode))
        #expect(AgentMarkAsset.isTemplate(.cursor))
        #expect(Agent.allCases.filter(AgentMarkAsset.isTemplate) == [.claudeCode, .cursor])
    }

    @Test func eachAgentMapsToItsExpectedBundledFormat() {
        #expect(AgentMarkAsset.resourceExtension(for: .claudeCode) == "svg")
        #expect(AgentMarkAsset.resourceExtension(for: .codex) == "png")
        #expect(AgentMarkAsset.resourceExtension(for: .cursor) == "svg")
        #expect(AgentMarkAsset.resourceExtension(for: .kiro) == "png")
        #expect(AgentMarkAsset.resourceExtension(for: .antigravity) == "png")
        #expect(AgentMarkAsset.resourceExtension(for: .opencode) == "svg")
    }
}
