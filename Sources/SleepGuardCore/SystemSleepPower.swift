import Darwin
import Foundation
import OSLog

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
        // A watchdog has no AppKit event loop to drain temporary Foundation
        // objects. Keep their lifetime bounded even during repeated failures.
        try autoreleasepool { try runCommand(arguments) }
    }

    private func runCommand(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        // Reading EOF and waiting for the child do not close our read end.
        // FileHandle.close() also safely tracks an end Foundation already closed;
        // never close its raw descriptor a second time (it may have been reused).
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        var stage = "create pipe"
        do {
            guard output.fileHandleForReading.fileDescriptor >= 0,
                  output.fileHandleForWriting.fileDescriptor >= 0 else {
                throw SleepGuardFailure("Couldn’t create the macOS power command connection.")
            }
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            stage = "launch"
            try process.run()
            stage = "wait"
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
            stage = "read output"
            return String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        } catch {
            let failure = error as NSError
            // The size query allocates no new descriptors, including at exhaustion.
            let descriptorBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            var descriptorBuffer = [UInt8](repeating: 0, count: max(0, Int(descriptorBytes)) + 32 * MemoryLayout<proc_fdinfo>.stride)
            let actualBytes = descriptorBuffer.withUnsafeMutableBytes {
                proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            let descriptors = actualBytes > 0 ? Int(actualBytes) / MemoryLayout<proc_fdinfo>.stride : -1
            Logger(subsystem: SleepGuardService.identifier, category: "PowerCommand").error(
                "Power command failed stage=\(stage, privacy: .public) arguments=\(arguments.joined(separator: " "), privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code) descriptors=\(descriptors) message=\(failure.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
