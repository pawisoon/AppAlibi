import Foundation

public enum LogReaderError: Error, CustomStringConvertible {
    case exited(status: Int32, message: String)

    public var description: String {
        switch self {
        case .exited(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "log exited with status \(status)" : detail
        }
    }
}

/// Runs `/usr/bin/log` and yields parsed entries in batches.
/// Always the full path: in zsh, the builtin `log` shadows the tool.
public enum LogReader {
    public static let executable = URL(fileURLWithPath: "/usr/bin/log")

    public static func showArguments(predicate: String, start: Date, end: Date? = nil) -> [String] {
        ["show", "--style", "ndjson", "--info", "--start", LogTimestamp.argument(for: start)]
            + (end.map { ["--end", LogTimestamp.argument(for: $0)] } ?? [])
            + ["--predicate", predicate]
    }

    public static func streamArguments(predicate: String) -> [String] {
        ["stream", "--style", "ndjson", "--level", "info", "--predicate", predicate]
    }

    public static func run(_ arguments: [String]) -> AsyncThrowingStream<[LogEntry], Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            RunningProcesses.shared.insert(process)

            let errorData = LockedData()
            let errorThread = Thread {
                errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
            }
            errorThread.start()

            let readThread = Thread {
                let handle = output.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    var entries: [LogEntry] = []
                    var lineStart = buffer.startIndex
                    while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                        if let entry = LogEntry.parse(buffer[lineStart..<newline]) { entries.append(entry) }
                        lineStart = buffer.index(after: newline)
                    }
                    buffer = Data(buffer[lineStart...])
                    if !entries.isEmpty { continuation.yield(entries) }
                }
                if let entry = LogEntry.parse(buffer) { continuation.yield([entry]) }
                process.waitUntilExit()
                RunningProcesses.shared.remove(process)

                if process.terminationReason == .exit, process.terminationStatus != 0 {
                    let message = String(decoding: errorData.waitAndGet(), as: UTF8.self)
                    continuation.finish(throwing: LogReaderError.exited(status: process.terminationStatus, message: message))
                } else {
                    continuation.finish()
                }
            }
            readThread.start()
        }
    }
}

extension LogReader {
    /// Terminates every `log` process this app started. Call when the app quits:
    /// child processes are not killed automatically when their parent exits.
    public static func terminateAll() {
        RunningProcesses.shared.terminateAll()
    }
}

private final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func insert(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = process
    }

    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = nil
    }

    func terminateAll() {
        lock.lock()
        let running = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
}

/// Holds stderr output until the reading thread finishes.
private final class LockedData: @unchecked Sendable {
    private let condition = NSCondition()
    private var data: Data?

    func set(_ value: Data) {
        condition.lock()
        data = value
        condition.signal()
        condition.unlock()
    }

    func waitAndGet() -> Data {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while data == nil, condition.wait(until: deadline) {}
        return data ?? Data()
    }
}
