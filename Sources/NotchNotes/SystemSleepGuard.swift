import Foundation

struct SystemSleepGuardCommand {
    let appProcessID: Int32
    let readyFileURL: URL
    let stopFileURL: URL

    var watcherCommand: String {
        let readyPath = Self.shellQuote(readyFileURL.path)
        let stopPath = Self.shellQuote(stopFileURL.path)

        return [
            "cleanup() { /usr/bin/pmset -a disablesleep 0; if ! /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1'; then /bin/rm -f \(readyPath) \(stopPath); fi; }",
            "trap cleanup 0",
            "trap 'exit 1' 1 2 15",
            "/usr/bin/pmset -a disablesleep 1 || exit 1",
            "/usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || exit 1",
            "/usr/bin/touch \(readyPath) || exit 1",
            "while /bin/kill -0 \(appProcessID) 2>/dev/null && [ ! -e \(stopPath) ]; do /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || /usr/bin/pmset -a disablesleep 1 || break; /bin/sleep 1; done"
        ].joined(separator: "; ")
    }

    var launcherCommand: String {
        let watcher = Self.shellQuote(watcherCommand)
        let readyPath = Self.shellQuote(readyFileURL.path)

        return "/usr/bin/nohup /bin/sh -c \(watcher) >/dev/null 2>&1 & helper_pid=$!; while [ ! -e \(readyPath) ]; do /bin/kill -0 \"$helper_pid\" 2>/dev/null || exit 1; /bin/sleep 0.1; done"
    }

    var appleScript: String {
        Self.administratorAppleScript(for: launcherCommand)
    }

    static var resetAppleScript: String {
        administratorAppleScript(for: "/usr/bin/pmset -a disablesleep 0")
    }

    static func sleepIsDisabled(in output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count >= 2
                    && fields[0] == "SleepDisabled"
                    && fields[1] == "1"
            }
    }

    private static func administratorAppleScript(for command: String) -> String {
        let escapedCommand = command
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
    private var launcherProcess: Process?
    private var readyFileURL: URL?
    private var stopFileURL: URL?

    var isRunning: Bool {
        guard let readyFileURL else {
            return launcherProcess?.isRunning == true
        }
        return FileManager.default.fileExists(atPath: readyFileURL.path)
            || launcherProcess?.isRunning == true
    }

    func start() throws {
        discardStoppedSession()
        guard launcherProcess == nil, readyFileURL == nil else { return }

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
        let process = Self.appleScriptProcess(command.appleScript)

        try process.run()
        launcherProcess = process
        self.readyFileURL = readyFileURL
        self.stopFileURL = stopFileURL
    }

    func waitUntilReady() async -> Bool {
        while !Task.isCancelled {
            guard let readyFileURL else { return false }
            if FileManager.default.fileExists(atPath: readyFileURL.path) {
                launcherProcess = nil
                return Self.sleepDisabledState() == true
            }
            if let launcherProcess, !launcherProcess.isRunning {
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

    func waitUntilStopped() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)

        while !Task.isCancelled, ContinuousClock.now < deadline {
            let readyFileExists = readyFileURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            if !readyFileExists, Self.sleepDisabledState() == false {
                discardStoppedSession()
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func resetSleepIfNeeded() async -> Bool {
        requestStop()

        if await waitUntilStopped() {
            return true
        }
        guard Self.sleepDisabledState() != false else {
            discardStoppedSession()
            return true
        }

        let process = Self.appleScriptProcess(SystemSleepGuardCommand.resetAppleScript)
        do {
            try process.run()
        } catch {
            return false
        }

        while !Task.isCancelled, process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let didReset = Self.sleepDisabledState() == false
        if didReset {
            clearSessionFiles()
        }
        return didReset
    }

    static func isSleepDisabled() -> Bool {
        sleepDisabledState() == true
    }

    private static func sleepDisabledState() -> Bool? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return SystemSleepGuardCommand.sleepIsDisabled(in: text)
        } catch {
            return nil
        }
    }

    private static func appleScriptProcess(_ source: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func discardStoppedSession() {
        guard launcherProcess?.isRunning != true else { return }

        if let readyFileURL,
           !FileManager.default.fileExists(atPath: readyFileURL.path) {
            try? FileManager.default.removeItem(at: readyFileURL)
        }
        if let stopFileURL {
            try? FileManager.default.removeItem(at: stopFileURL)
        }
        launcherProcess = nil
        readyFileURL = nil
        stopFileURL = nil
    }

    private func clearSessionFiles() {
        if let readyFileURL {
            try? FileManager.default.removeItem(at: readyFileURL)
        }
        if let stopFileURL {
            try? FileManager.default.removeItem(at: stopFileURL)
        }
        launcherProcess = nil
        readyFileURL = nil
        stopFileURL = nil
    }
}
