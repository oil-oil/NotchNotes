import Foundation

struct SystemSleepGuardCommand {
    let appProcessID: Int32
    let readyFileURL: URL
    let stopFileURL: URL

    var shellCommand: String {
        let readyPath = Self.shellQuote(readyFileURL.path)
        let stopPath = Self.shellQuote(stopFileURL.path)

        return [
            "original_state=0",
            "/usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' && original_state=1",
            "cleanup() { /usr/bin/pmset -a disablesleep \"$original_state\"; /bin/rm -f \(readyPath) \(stopPath); }",
            "trap cleanup 0 1 2 15",
            "/usr/bin/pmset -a disablesleep 1 || exit 1",
            "/usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || exit 1",
            "/usr/bin/touch \(readyPath) || exit 1",
            "while /bin/kill -0 \(appProcessID) 2>/dev/null && [ ! -e \(stopPath) ]; do /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || /usr/bin/pmset -a disablesleep 1; /bin/sleep 1; done"
        ].joined(separator: "; ")
    }

    var appleScript: String {
        let escapedCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        with timeout of 2147483647 seconds
            do shell script "\(escapedCommand)" with administrator privileges
        end timeout
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
final class SystemSleepGuard {
    private var process: Process?
    private var readyFileURL: URL?
    private var stopFileURL: URL?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() throws {
        discardStoppedSession()
        guard process == nil else { return }

        let token = UUID().uuidString
        let baseName = "NotchNotes-KeepAwake-\(ProcessInfo.processInfo.processIdentifier)-\(token)"
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let readyFileURL = temporaryDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension("ready")
        let stopFileURL = temporaryDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension("stop")

        try? FileManager.default.removeItem(at: readyFileURL)
        try? FileManager.default.removeItem(at: stopFileURL)

        let command = SystemSleepGuardCommand(
            appProcessID: ProcessInfo.processInfo.processIdentifier,
            readyFileURL: readyFileURL,
            stopFileURL: stopFileURL
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", command.appleScript]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        self.process = process
        self.readyFileURL = readyFileURL
        self.stopFileURL = stopFileURL
    }

    func waitUntilReady() async -> Bool {
        while !Task.isCancelled {
            guard let process, let readyFileURL else { return false }
            if FileManager.default.fileExists(atPath: readyFileURL.path) {
                return true
            }
            if !process.isRunning {
                discardStoppedSession()
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func requestStop() {
        guard let stopFileURL else {
            discardStoppedSession()
            return
        }
        FileManager.default.createFile(atPath: stopFileURL.path, contents: Data())
    }

    func waitUntilStopped() async {
        while !Task.isCancelled, process?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        discardStoppedSession()
    }

    private func discardStoppedSession() {
        guard process?.isRunning != true else { return }

        if let readyFileURL {
            try? FileManager.default.removeItem(at: readyFileURL)
        }
        if let stopFileURL {
            try? FileManager.default.removeItem(at: stopFileURL)
        }
        process = nil
        readyFileURL = nil
        stopFileURL = nil
    }
}
