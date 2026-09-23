import Darwin
import Foundation

/// What detection needs from the operating system. Read-only: nothing here writes to,
/// signals or kills another process.
public protocol ProcessSource: Sendable {
    /// The text of `ps -Ao pid,ppid,tty,lstart,command`.
    func processList() throws -> String
    /// A process's working directory, or nil when it cannot be read.
    func workingDirectory(of pid: Int32) -> String?
}

/// The live system: runs `/bin/ps` and asks libproc for working directories.
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
}
