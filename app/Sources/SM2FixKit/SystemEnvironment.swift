import Foundation

/// The result of running a command-line tool.
public struct CommandResult: Equatable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs command-line tools (wine, ps). Replaced by a fake in tests.
public protocol CommandRunner {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> CommandResult
}

/// Runs tools with `Process`, killing them if they take longer than the timeout.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "\(error.localizedDescription)")
        }
        // Read while it runs so a chatty tool can't fill the pipe and stall.
        var data = Data()
        let reader = DispatchQueue(label: "sm2fix.reader")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            _ = readDone.wait(timeout: .now() + 2)
            return CommandResult(status: -2, output: "timed out after \(Int(timeout)) s")
        }
        _ = readDone.wait(timeout: .now() + 5)
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Everything the app looks at outside the game folder: the home folder (bottles) and
/// running processes. Tests point it at a temporary folder and a fake command runner.
/// The only program the app runs besides the shader tools is /bin/ps.
public struct SystemEnvironment {
    public var home: URL
    public var runner: CommandRunner

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, runner: CommandRunner = ProcessRunner()) {
        self.home = home
        self.runner = runner
    }

    /// The command lines of all running processes.
    public func runningProcesses() -> [String] {
        let result = runner.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "args="], environment: [:], timeout: 10)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map { String($0) }
    }

    /// Whether Spider-Man 2 is running.
    public func gameIsRunning() -> Bool {
        runningProcesses().contains { $0.contains(GameFinder.exeName) }
    }

    /// Whether any Wine is running (it would overwrite registry edits when it exits).
    /// CrossOver's path can contain spaces ("CrossOver Preview.app", "CrossOver-Hosted
    /// Application"), and CrossOver Preview names it wineserver-arm64 or wineserver-x86.
    public func wineIsRunning() -> Bool {
        runningProcesses().contains { line in
            line.range(of: #"(^|/)wineserver(-[A-Za-z0-9_]+)?( |$)"#, options: .regularExpression) != nil
        }
    }
}

extension URL {
    /// The path with symlinks resolved, for comparing locations.
    var canonicalPath: String {
        resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether `self` is `other` or inside it.
    func isInside(_ other: URL) -> Bool {
        let me = canonicalPath, parent = other.canonicalPath
        return me == parent || me.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
