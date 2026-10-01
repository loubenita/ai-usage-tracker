import Foundation
import Testing
@testable import UsageData

/// Reading another process's environment is tested on buffers built by hand in the layout the
/// system's `KERN_PROCARGS2` answer has, not on other processes.
@Suite("Reading a process's environment")
struct ProcessEnvironmentTests {
    let link = "warp://session/68e41dbb3b9145cd8714ffffcae1a24e"

    /// The layout `sysctl` answers with: the argument count, the executable's path, NUL padding,
    /// the arguments, the environment, an empty string, and then strings the system adds.
    func buffer(
        argc: Int32? = nil,
        arguments: [String] = ["claude", "--dangerously-skip-permissions"],
        environment: [String],
        padding: Int = 5,
        afterTheEnvironment: [String] = ["executable_path=/Users/me/.local/bin/claude"]
    ) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc ?? Int32(arguments.count)) { Array($0) }
        bytes += Array("/Users/me/.local/bin/claude".utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        for variable in environment { bytes += Array(variable.utf8) + [0] }
        bytes.append(0)
        for extra in afterTheEnvironment { bytes += Array(extra.utf8) + [0] }
        return bytes
    }

    func value(_ name: String, in bytes: [UInt8]) -> String? {
        ProcessEnvironment.value(named: name, inProcessArguments: bytes)
    }

    @Test func findsAVariable() {
        let bytes = buffer(environment: ["HOME=/Users/me", "WARP_FOCUS_URL=\(link)", "TERM=xterm-256color"])
        #expect(value("WARP_FOCUS_URL", in: bytes) == link)
        #expect(value("HOME", in: bytes) == "/Users/me")
        #expect(value("TERM", in: bytes) == "xterm-256color")
    }

    @Test func aMissingVariableIsNil() {
        let bytes = buffer(environment: ["HOME=/Users/me", "TERM=xterm-256color"])
        #expect(value("WARP_FOCUS_URL", in: bytes) == nil)
        // A name is matched whole: HOM is not HOME.
        #expect(value("HOM", in: bytes) == nil)
        #expect(value("", in: bytes) == nil)
    }

    @Test func aVariableWhoseNameOnlyStartsWithTheOneAskedForIsNotIt() {
        let bytes = buffer(environment: ["WARP_FOCUS_URL_OLD=nope", "XWARP_FOCUS_URL=nope", "WARP_FOCUS_URL=\(link)"])
        #expect(value("WARP_FOCUS_URL", in: bytes) == link)
        #expect(value("WARP_FOCUS_URL", in: buffer(environment: ["WARP_FOCUS_URL_OLD=nope"])) == nil)
    }

    @Test func keepsEverythingAfterTheFirstEqualsSignAndAnEmptyValue() {
        let bytes = buffer(environment: ["A=b=c", "EMPTY="])
        #expect(value("A", in: bytes) == "b=c")
        #expect(value("EMPTY", in: bytes) == "")
    }

    @Test func anArgumentThatLooksLikeAVariableIsNotOne() {
        let bytes = buffer(arguments: ["env", "WARP_FOCUS_URL=bad", "claude"], environment: ["HOME=/Users/me"])
        #expect(value("WARP_FOCUS_URL", in: bytes) == nil)
        #expect(value("HOME", in: bytes) == "/Users/me")
    }

    @Test func anEmptyArgumentDoesNotThrowOffTheCount() {
        let bytes = buffer(arguments: ["claude", "", "--name", ""], environment: ["WARP_FOCUS_URL=\(link)"])
        #expect(value("WARP_FOCUS_URL", in: bytes) == link)
    }

    @Test func stringsAfterTheEnvironmentAreNotTheEnvironment() {
        let bytes = buffer(environment: ["HOME=/Users/me"], afterTheEnvironment: ["WARP_FOCUS_URL=\(link)"])
        #expect(value("WARP_FOCUS_URL", in: bytes) == nil)
    }

    @Test func aProcessWithNoArgumentsOrNoPaddingStillReads() {
        #expect(value("A", in: buffer(arguments: [], environment: ["A=1"])) == "1")
        #expect(value("A", in: buffer(environment: ["A=1"], padding: 0)) == "1")
    }

    @Test func aTruncatedBufferNeverCrashesAndNeverGivesAPartValue() {
        let full = buffer(environment: ["HOME=/Users/me", "WARP_FOCUS_URL=\(link)", "TERM=xterm-256color"])
        for length in 0...full.count {
            let found = value("WARP_FOCUS_URL", in: Array(full.prefix(length)))
            #expect(found == nil || found == link, "cut at \(length) gave \(String(describing: found))")
        }
        // Cut in the middle of the value: it is not returned short.
        let end = full.count - "TERM=xterm-256color".utf8.count - 1 - 1 - "executable_path=/Users/me/.local/bin/claude".utf8.count - 1
        #expect(value("WARP_FOCUS_URL", in: Array(full.prefix(end - 10))) == nil)
        // Cut just after the value's NUL: it is complete, so it is returned.
        #expect(value("WARP_FOCUS_URL", in: Array(full.prefix(end))) == link)
    }

    @Test func aBufferThatPromisesMoreThanItHoldsIsNil() {
        #expect(value("HOME", in: []) == nil)
        #expect(value("HOME", in: [1]) == nil)
        #expect(value("HOME", in: [1, 0, 0, 0]) == nil)
        #expect(value("HOME", in: buffer(argc: 50, environment: ["HOME=/Users/me"])) == nil)
        #expect(value("HOME", in: buffer(argc: -1, environment: ["HOME=/Users/me"])) == nil)
        // No ending NUL anywhere after the count.
        #expect(value("HOME", in: [1, 0, 0, 0] + Array("/bin/claude".utf8)) == nil)
    }

    @Test func readsTheTestProcessItselfAndRefusesAProcessThatIsNotThere() {
        let own = ProcessInfo.processInfo.processIdentifier
        let bytes = ProcessEnvironment.arguments(of: own)
        #expect(bytes != nil)
        #expect(ProcessEnvironment.value(named: "A_VARIABLE_NOBODY_SETS_8F3A", of: own) == nil)
        #expect(ProcessEnvironment.arguments(of: Int32.max) == nil)
        #expect(ProcessEnvironment.value(named: "HOME", of: Int32.max) == nil)
    }
}
