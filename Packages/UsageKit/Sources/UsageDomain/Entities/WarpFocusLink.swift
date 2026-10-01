import Foundation

/// The link Warp gives each of its tabs. Every process started in a Warp tab has it in its
/// environment as `WARP_FOCUS_URL`, such as `warp://session/68e41dbb3b9145cd8714ffffcae1a24e`,
/// and opening it makes Warp switch to exactly that tab.
///
/// The value comes from another process's environment and is then opened as a URL, so only the
/// one exact shape is accepted: `warp://session/` and 32 lowercase hex digits, nothing else.
public enum WarpFocusLink {
    /// The environment variable Warp sets in every tab.
    public static let variable = "WARP_FOCUS_URL"

    private static let prefix = "warp://session/"
    private static let idLength = 32

    /// The link itself when it has exactly that shape, otherwise nil.
    public static func validated(_ value: String?) -> String? {
        guard let value, value.utf8.count == prefix.utf8.count + idLength,
              value.utf8.starts(with: prefix.utf8) else { return nil }
        let isLowercaseHex = { (byte: UInt8) in (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) }
        return value.utf8.dropFirst(prefix.utf8.count).allSatisfy(isLowercaseHex) ? value : nil
    }
}
