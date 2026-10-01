import Darwin
import Foundation

/// What detection needs from the operating system. Read-only: nothing here writes to,
/// signals or kills another process.
public protocol ProcessSource: Sendable {
    /// The text of `ps -Ao pid,ppid,tty,lstart,command`.
    func processList() throws -> String
    /// A process's working directory, or nil when it cannot be read.
    func workingDirectory(of pid: Int32) -> String?
    /// One variable of the environment a process was started with, or nil when it cannot be
    /// read (only processes of the same user can be) or does not have it.
    func environmentValue(_ name: String, of pid: Int32) -> String?
}

extension ProcessSource {
    /// A source that cannot read environments, such as a recorded one, finds nothing.
    public func environmentValue(_ name: String, of pid: Int32) -> String? { nil }
}

/// The live system: runs `/bin/ps`, asks libproc for working directories and reads another
/// process's environment through `sysctl`.
public struct SystemProcessSource: ProcessSource {
    public init() {}

    public func processList() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -ww: never cut long command lines. LC_ALL=C: a start time format that does not
        // depend on the user's language.
        process.arguments = ["-ww", "-Ao", "pid,ppid,tty,lstart,command"]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    public func environmentValue(_ name: String, of pid: Int32) -> String? {
        ProcessEnvironment.value(named: name, of: pid)
    }
}
