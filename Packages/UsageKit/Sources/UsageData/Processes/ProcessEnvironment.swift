import Darwin
import Foundation

/// Reads the environment another process was started with. Read-only, and only for processes of
/// the same user: for any other the system refuses and the answer is nil.
enum ProcessEnvironment {
    /// The value of one variable of a process, or nil when the process cannot be read or does not
    /// have the variable.
    static func value(named name: String, of pid: Int32) -> String? {
        arguments(of: pid).flatMap { value(named: name, inProcessArguments: $0) }
    }

    /// What `sysctl` answers for `KERN_PROCARGS2`, or nil when it refuses.
    static func arguments(of pid: Int32) -> [UInt8]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Looks one variable up in a `KERN_PROCARGS2` buffer. The buffer holds, in this order:
    ///
    /// 1. the argument count, `argc`, as a native `Int32`
    /// 2. the path of the executable, ended by NUL
    /// 3. NUL padding
    /// 4. the `argc` arguments, each ended by NUL
    /// 5. the environment, one `KEY=VALUE` string at a time, each ended by NUL, up to an empty string
    ///
    /// A buffer that stops early (a string with no ending NUL, or fewer strings than it promises)
    /// gives nil rather than a value that may be cut short.
    static func value(named name: String, inProcessArguments buffer: [UInt8]) -> String? {
        let countSize = MemoryLayout<Int32>.size
        guard !name.isEmpty, buffer.count > countSize else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }

        var index = countSize
        // The executable's path, then the NUL padding that follows it.
        guard skipString(in: buffer, at: &index) else { return nil }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        for _ in 0..<argc {
            guard skipString(in: buffer, at: &index) else { return nil }
        }

        let wanted = Array((name + "=").utf8)
        while index < buffer.count {
            let start = index
            guard skipString(in: buffer, at: &index) else { return nil }
            let end = index - 1
            // An empty string ends the environment.
            if end == start { return nil }
            if buffer[start..<end].starts(with: wanted) {
                return String(decoding: buffer[(start + wanted.count)..<end], as: UTF8.self)
            }
        }
        return nil
    }

    /// Moves `index` past the string that starts there and its ending NUL. False when the buffer
    /// ends before the NUL.
    private static func skipString(in buffer: [UInt8], at index: inout Int) -> Bool {
        guard let end = buffer[index...].firstIndex(of: 0) else { return false }
        index = end + 1
        return true
    }
}
