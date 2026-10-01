import Testing
@testable import UsageDomain

/// The link Warp gives each tab is read from another process's environment and then opened as a
/// URL, so only its exact shape gets through.
@Suite("Warp tab links")
struct WarpFocusLinkTests {
    let real = "warp://session/68e41dbb3b9145cd8714ffffcae1a24e"

    @Test func acceptsTheLinkWarpGivesATab() {
        #expect(WarpFocusLink.validated(real) == real)
        #expect(WarpFocusLink.validated("warp://session/00000000000000000000000000000000") != nil)
        #expect(WarpFocusLink.validated("warp://session/ffffffffffffffffffffffffffffffff") != nil)
        #expect(WarpFocusLink.variable == "WARP_FOCUS_URL")
    }

    @Test func rejectsAnythingElse() {
        let id = "68e41dbb3b9145cd8714ffffcae1a24e"
        let rejected: [String?] = [
            nil,
            "",
            // Uppercase hex.
            "warp://session/" + id.uppercased(),
            // Another scheme, or no scheme.
            "https://session/" + id,
            "warp-preview://session/" + id,
            "WARP://session/" + id,
            "session/" + id,
            // Another host or an extra part of the path.
            "warp://tab/" + id,
            "warp://session/" + id + "/extra",
            "warp://session//" + id,
            "warp://session/" + id + "/",
            // A query or a fragment.
            "warp://session/" + id + "?x=1",
            "warp://session/" + id + "#top",
            // 31 and 33 digits.
            "warp://session/" + String(id.dropLast()),
            "warp://session/" + id + "0",
            // A digit that is not hex.
            "warp://session/" + String(id.dropLast()) + "g",
            // Spaces, quotes, a newline, a control character, a lookalike digit.
            " warp://session/" + id,
            "warp://session/" + id + " ",
            "warp://session/" + id + "\n",
            "\"warp://session/" + id + "\"",
            "'warp://session/" + id + "'",
            "warp://session/" + id + " \"; open -a Calculator",
            "warp://session/" + String(id.dropLast()) + "\u{0}",
            "warp://session/" + String(id.dropLast()) + "\u{FF11}",
        ]
        for value in rejected {
            #expect(WarpFocusLink.validated(value) == nil, "accepted \(String(describing: value))")
        }
    }
}
