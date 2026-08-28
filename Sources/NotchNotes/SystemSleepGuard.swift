import Foundation

enum SystemSleepGuardError: Error, Equatable {
    case authorizationCancelled
    case authorizationDenied
    case helperLaunchFailed(String)
    case stateVerificationFailed

    var userMessage: String? {
        switch self {
        case .authorizationCancelled:
            return nil
        case .authorizationDenied:
            return "Administrator permission was denied."
        case .helperLaunchFailed:
            return "The keep-awake helper couldn’t start. Please try again."
        case .stateVerificationFailed:
            return "macOS didn’t enable closed-lid keep-awake mode. Please try again."
        }
    }

    static func fromAppleScriptError(_ message: String) -> Self {
        if message.contains("(-128)") || message.localizedCaseInsensitiveContains("user canceled") {
            return .authorizationCancelled
        }
        if message.contains("(-60005)") || message.localizedCaseInsensitiveContains("not authorized") {
            return .authorizationDenied
        }
        return .helperLaunchFailed(message)
    }
}

@MainActor
protocol SystemSleepGuardControlling: AnyObject {
    var isRunning: Bool { get }

    func start() throws
    func waitUntilReady() async throws
    func requestStop()
    func resetSleepIfNeeded() async -> Bool
}

struct SystemSleepGuardCommand {
    let appProcessID: Int32
    let readyFileURL: URL
    let stopFileURL: URL
    let pmsetExecutable: String

    init(
        appProcessID: Int32,
        readyFileURL: URL,
        stopFileURL: URL,
        pmsetExecutable: String = "/usr/bin/pmset"
    ) {
        self.appProcessID = appProcessID
        self.readyFileURL = readyFileURL
        self.stopFileURL = stopFileURL
        self.pmsetExecutable = pmsetExecutable
    }

    var watcherCommand: String {
        let readyPath = Self.shellQuote(readyFileURL.path)
        let stopPath = Self.shellQuote(stopFileURL.path)
        let pmsetPath = Self.shellQuote(pmsetExecutable)

        return [
            "cleanup() { \(pmsetPath) -a disablesleep 0; if ! \(pmsetPath) -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1'; then /bin/rm -f \(readyPath) \(stopPath); fi; }",
            "trap cleanup 0",
            "trap 'exit 1' 1 2 15",
            "\(pmsetPath) -a disablesleep 1 || exit 1",
            "\(pmsetPath) -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || exit 1",
            "/usr/bin/touch \(readyPath) || exit 1",
            "while /bin/kill -0 \(appProcessID) 2>/dev/null && [ ! -e \(stopPath) ]; do \(pmsetPath) -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || \(pmsetPath) -a disablesleep 1 || break; /bin/sleep 1; done"
        ].joined(separator: "; ")
    }

    var appleScript: String {
        Self.administratorAppleScript(for: watcherCommand)
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
final class SystemSleepGuard: SystemSleepGuardControlling {
    private var launcherProcess: Process?
    private var launcherErrorPipe: Pipe?
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
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        launcherProcess = process
        launcherErrorPipe = errorPipe
        self.readyFileURL = readyFileURL
        self.stopFileURL = stopFileURL
    }

    func waitUntilReady() async throws {
        while !Task.isCancelled {
            guard let readyFileURL else {
                throw SystemSleepGuardError.helperLaunchFailed("Missing readiness marker.")
            }
            if FileManager.default.fileExists(atPath: readyFileURL.path) {
                guard Self.sleepDisabledState() == true else {
                    throw SystemSleepGuardError.stateVerificationFailed
                }
                return
            }
            if let launcherProcess, !launcherProcess.isRunning {
                let message = readLauncherError()
                discardStoppedSession()
                throw SystemSleepGuardError.fromAppleScriptError(message)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
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
        launcherErrorPipe = nil
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
        launcherErrorPipe = nil
        readyFileURL = nil
        stopFileURL = nil
    }

    private func readLauncherError() -> String {
        guard let launcherErrorPipe else { return "Unknown helper error." }
        let data = launcherErrorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "Unknown helper error."
    }
}
