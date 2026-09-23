import Foundation
import Synchronization
import UsageDomain

/// Runs a program and returns what it printed, or nil when it could not start, failed, or did
/// not finish in time. A protocol so the tests never start a real `kiro-cli`.
protocol CommandRunner: Sendable {
    func run(_ executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> String?
}

/// Asks `kiro-cli` for the plan every few minutes, in the background, and keeps the answer.
///
/// This is the one place the app runs another program: Kiro keeps the plan's credits on its
/// servers, and `kiro-cli chat --no-interactive "/usage"` is how Kiro's own tool reads them
/// (CodexBar reads them the same way). It only asks; it changes nothing in Kiro. It runs in a
/// folder of the app's own, so the chat Kiro opens to answer is never taken for one of the
/// person's sessions, and it is stopped if it takes longer than `timeout`.
final class KiroPlanReader: Sendable {
    static let interval: TimeInterval = 5 * 60
    static let timeout: TimeInterval = 20
    static let arguments = ["chat", "--no-interactive", "/usage"]
    /// The app's own folder `kiro-cli` runs in.
    static let folderName = "AIUsageTracker-kiro"

    /// Where Kiro's installer and package managers put `kiro-cli`.
    static func candidates(homeDirectory: String) -> [String] {
        [
            homeDirectory + "/.local/bin/kiro-cli",
            "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli",
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
        ]
    }

    private struct State {
        var plan: PlanUsage?
        var askedAt: Date?
        var isAsking = false
    }

    private let executable: String?
    private let directory: String
    private let runner: any CommandRunner
    private let calendar: Calendar
    private let state = Mutex(State())

    init(
        homeDirectory: String,
        directory: String = FileManager.default.temporaryDirectory.appendingPathComponent(KiroPlanReader.folderName).path,
        runner: any CommandRunner = ProcessCommandRunner(),
        calendar: Calendar = .current,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.executable = Self.candidates(homeDirectory: homeDirectory).first(where: isExecutable)
        self.directory = directory
        self.runner = runner
        self.calendar = calendar
    }

    /// Whether `kiro-cli` is installed; without it there is nothing to ask.
    var isAvailable: Bool { executable != nil }

    /// The last plan read, asking again in the background when the last answer is old.
    /// A failed ask keeps the last plan rather than showing none.
    func current(now: Date) -> PlanUsage? {
        guard let executable else { return nil }
        let due = state.withLock { state -> Bool in
            guard !state.isAsking else { return false }
            if let askedAt = state.askedAt, now.timeIntervalSince(askedAt) < Self.interval { return false }
            state.isAsking = true
            return true
        }
        if due {
            Task.detached(priority: .utility) { self.ask(executable, now: now) }
        }
        return state.withLock { $0.plan }
    }

    /// Asks once and keeps the answer. Waits for `kiro-cli`, so it runs off the main thread.
    func ask(_ executable: String, now: Date) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let plan = runner.run(executable, arguments: Self.arguments, directory: directory, timeout: Self.timeout)
            .flatMap { KiroUsageReport.plan(in: $0, readAt: now, calendar: calendar) }
        state.withLock { state in
            if let plan { state.plan = plan }
            state.askedAt = now
            state.isAsking = false
        }
    }
}

/// Runs a real program, with no terminal, and stops it if it overruns.
struct ProcessCommandRunner: CommandRunner {
    func run(_ executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs, so a full pipe never stops it.
        let data = Mutex(Data())
        let reader = DispatchQueue(label: "kiro-cli output")
        reader.async {
            let all = output.fileHandleForReading.readDataToEndOfFile()
            data.withLock { $0 = all }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Only the program this reader started is stopped.
            process.terminate()
            return nil
        }
        reader.sync {}
        // The exit status is not trusted either way: the report is read from what was printed.
        return String(decoding: data.withLock { $0 }, as: UTF8.self)
    }
}
