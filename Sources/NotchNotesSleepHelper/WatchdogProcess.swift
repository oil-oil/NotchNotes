import Darwin
import Foundation
import SleepGuardCore

// Only the daemon queue accesses this object. No power setting is changed here;
// a separate process owns enable/lease/restore under one exclusive journal lock.
final class WatchdogProcess {
    private let executable: URL
    private let journal: any SleepOwnershipStoring
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var owner: UUID?

    init(executable: URL, journal: any SleepOwnershipStoring) {
        self.executable = executable
        self.journal = journal
    }

    func begin(session: UUID) throws {
        guard owner == nil || owner == session else {
            throw SleepGuardFailure("Another NotchNotes instance is already keeping this Mac awake.")
        }
        if owner == session { try renew(session: session); return }
        try finishPreviousProcess()
        let (child, writer, reader) = try launch(mode: "--watchdog")
        process = child
        input = writer
        output = reader
        do {
            try awaitReply(reader: reader, expected: "READY", timeout: 4)
            owner = session
            try renew(session: session)
        } catch {
            owner = nil
            cleanUpAfterFailure()
            throw error
        }
    }

    func renew(session: UUID) throws {
        guard owner == session else {
            throw SleepGuardFailure("This connection doesn’t own the keep-awake session.")
        }
        guard let process, process.isRunning, let input, let output else {
            owner = nil
            throw SleepGuardFailure("The keep-awake worker exited. Click the coffee cup to start again.", code: .workerExited)
        }
        do {
            try input.write(contentsOf: Data("\(ProcessInfo.processInfo.systemUptime)\n".utf8))
            try awaitReply(reader: output, expected: "ALIVE", timeout: 2)
        } catch {
            owner = nil
            cleanUpAfterFailure()
            throw error
        }
    }

    func end(session: UUID) throws {
        guard owner == session else { return }
        owner = nil
        try finishPreviousProcess()
        try recoverAfterRestart()
    }

    func shutdown() throws {
        owner = nil
        try finishPreviousProcess()
        try recoverAfterRestart()
    }

    func recover() throws {
        try recover(mode: "--recover")
    }

    func recoverAfterRestart() throws {
        if owner == nil, try journal.isOwned() { try recover(mode: "--recover-owned") }
    }

    func recoverIfWorkerExited() throws {
        guard process?.isRunning != true else { return }
        owner = nil
        try finishPreviousProcess()
        try recoverAfterRestart()
    }

    private func recover(mode: String) throws {
        guard owner == nil else { throw SleepGuardFailure("A keep-awake session is still active.") }
        try finishPreviousProcess()
        // This explicit recovery also handles the global flag left by old builds.
        let (child, writer, reader) = try launch(mode: mode)
        // Retain the child even if its handshake fails, so cleanup can reap it
        // before a subsequent recovery attempts to acquire the journal lock.
        process = child
        input = writer
        output = reader
        do {
            try writer.close()
            input = nil
            try awaitReply(reader: reader, expected: "READY", timeout: 4)
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !child.isRunning else { throw SleepGuardFailure("Sleep recovery hasn’t finished yet.") }
            child.waitUntilExit()
            guard child.terminationStatus == 0 else { throw SleepGuardFailure("Normal sleep couldn’t be restored.") }
            try finishPreviousProcess()
        } catch {
            // Do not recursively recover here. The daemon's recovery timer retries
            // the durable journal; preserve the original failure for the caller.
            do { try finishPreviousProcess() }
            catch { logger.error("Recovery cleanup failed: \(error.localizedDescription, privacy: .public)") }
            throw error
        }
    }

    private func cleanUpAfterFailure() {
        do {
            try finishPreviousProcess()
            try recoverAfterRestart()
        } catch {
            // Cleanup must not replace the error that ended the user's session.
            // Keep the process/journal available for the daemon's next retry.
            logger.error("Session cleanup will retry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finishPreviousProcess() throws {
        // Closing either end must not skip cleanup of the other end or child.
        for handle in [input, output] {
            do { try handle?.close() }
            catch { logger.error("Watchdog pipe close failed: \(error.localizedDescription, privacy: .public)") }
        }
        input = nil
        output = nil
        guard let process else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            // A stalled child cannot process EOF. Terminate only this managed
            // worker; its durable marker is recovered under the same file lock.
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !process.isRunning else {
                throw SleepGuardFailure("The keep-awake watchdog is still restoring normal sleep.")
            }
        }
        process.waitUntilExit()
        self.process = nil
    }

    private func launch(mode: String) throws -> (Process, FileHandle, FileHandle) {
        try autoreleasepool {
            let child = Process()
            let lease = Pipe()
            let response = Pipe()
            var transferred = false
            defer {
                // These are the child's ends. Process.run may already close them.
                try? lease.fileHandleForReading.close()
                try? response.fileHandleForWriting.close()
                if !transferred {
                    try? lease.fileHandleForWriting.close()
                    try? response.fileHandleForReading.close()
                }
            }
            for handle in [lease.fileHandleForReading, lease.fileHandleForWriting,
                           response.fileHandleForReading, response.fileHandleForWriting] {
                guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                    throw SleepGuardFailure("Couldn’t create the sleep watchdog connection.")
                }
            }
            child.executableURL = executable
            child.arguments = [mode]
            child.standardInput = lease
            child.standardOutput = response
            child.standardError = FileHandle.nullDevice
            try child.run()
            transferred = true
            return (child, lease.fileHandleForWriting, response.fileHandleForReading)
        }
    }

    private func awaitReply(reader: FileHandle, expected: String, timeout: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                // Foundation may wait to fill read(upToCount:) on a live pipe.
                // One POSIX read returns the bytes currently available, keeping
                // the watchdog handshake and its timeout independent.
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(reader.fileDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw SleepGuardFailure("The sleep watchdog connection failed.") }
                data.append(contentsOf: buffer.prefix(count))
                if data.contains(10) {
                    let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("ERROR: ") {
                        throw SleepGuardFailure.fromWire(String(line.dropFirst(7)))
                    }
                    guard line == expected else { throw SleepGuardFailure(line) }
                    return
                }
                if count == 0 {
                    throw SleepGuardFailure("The keep-awake worker exited before replying. The session has stopped.", code: .workerExited)
                }
            }
        }
        throw SleepGuardFailure("The keep-awake worker did not reply in time. The session has stopped.", code: .timedOut)
    }
}

func runWatchdog(
    journal: any SleepOwnershipStoring,
    mode: String,
    power: any SleepPowerControlling = SystemSleepPower()
) throws {
    // launchd may signal the whole process group; the parent closes its lease on
    // SIGTERM. If it is stalled, the monotonic timeout still releases sleep.
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] { signal(signalNumber, SIG_IGN) }
    let controller = SleepLeaseController(power: power, ownership: journal)
    let idleSleepHelper = Process()
    idleSleepHelper.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    idleSleepHelper.arguments = ["-dims", "-w", String(getpid())]
    idleSleepHelper.standardInput = FileHandle.nullDevice
    idleSleepHelper.standardOutput = FileHandle.nullDevice
    idleSleepHelper.standardError = FileHandle.nullDevice
    defer { if idleSleepHelper.isRunning { idleSleepHelper.terminate() } }
    let startedAt = ProcessInfo.processInfo.systemUptime
    var renewals = 0
    do {
        // Startup and failed enable are covered by the same retrying cleanup as
        // an expired lease; a one-shot rollback must never leave sleep disabled.
        try controller.recoverAfterRestart()
        if mode != "--watchdog" {
            if mode == "--recover" { try controller.recoverLegacySleep() }
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            return
        }
        let session = UUID()
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        if poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLHUP) != 0 { return }
        try controller.begin(session: session)
        // Display/idle assertions share the independent watchdog's lifetime.
        // They expire on a lost lease even when the UI app is still hung.
        try idleSleepHelper.run()
        var lastPulse = ProcessInfo.processInfo.systemUptime
        try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
        while ProcessInfo.processInfo.systemUptime < lastPulse + SleepGuardService.leaseDuration {
            let shouldContinue = try autoreleasepool { () throws -> Bool in
                descriptor.revents = 0
                let result = poll(&descriptor, 1, 200)
                guard result >= 0 || errno == EINTR else { return false }
                try controller.tick()
                if result > 0 {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count <= 0 { return false }
                    let now = ProcessInfo.processInfo.systemUptime
                    let stamps = String(decoding: buffer.prefix(count), as: UTF8.self)
                        .split(separator: "\n").compactMap { TimeInterval($0) }
                    guard let latest = stamps.max(), latest > lastPulse,
                          latest <= now, now - latest < SleepGuardService.leaseDuration else { return false }
                    // Timestamp the lease at send time, so buffered renewals cannot
                    // keep an abandoned session alive when the daemon is stalled.
                    try controller.renew(session: session)
                    try FileHandle.standardOutput.write(contentsOf: Data("ALIVE\n".utf8))
                    lastPulse = latest
                    renewals += 1
                }
                return true
            }
            if !shouldContinue { break }
        }
    } catch {
        logger.error("Watchdog lease ended after \(ProcessInfo.processInfo.systemUptime - startedAt) seconds, renewals=\(renewals): \(error.localizedDescription, privacy: .public)")
        // Preserve runtime failures as well as startup failures. Otherwise a
        // clean worker exit is incorrectly reported as an unresponsive helper.
        let failure = SleepGuardFailure.wrapping(error)
        try? FileHandle.standardOutput.write(contentsOf: Data("ERROR: \(failure.wireMessage)\n".utf8))
    }
    if idleSleepHelper.isRunning { idleSleepHelper.terminate() }
    // Retry even after the UI and daemon are gone; keep the journal locked so
    // an old cleanup can never disable a newly enabled session.
    while true {
        let restored = autoreleasepool {
            do { try controller.shutdown(); return true }
            catch {
                logger.error("Watchdog recovery will retry: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        if restored { return }
        Thread.sleep(forTimeInterval: 1)
    }
}
