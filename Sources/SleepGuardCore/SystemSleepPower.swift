import Foundation

public struct SystemSleepPower: SleepPowerControlling {
    private let executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/pmset")) {
        self.executable = executable
    }

    public func isSleepDisabled() throws -> Bool {
        SleepGuardPowerState.isDisabled(in: try run(["-g"]))
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        _ = try run(["-a", "disablesleep", disabled ? "1" : "0"])
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            // A stuck command must not prevent lease expiration/recovery forever.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SleepGuardFailure("The macOS power command timed out.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SleepGuardFailure("The macOS power setting couldn’t be changed.")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
