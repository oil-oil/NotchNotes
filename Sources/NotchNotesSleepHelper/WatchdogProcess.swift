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
            try? writer.close()
            input = nil
            throw error
        }
    }

    func renew(session: UUID) throws {
        guard owner == session else {
            throw SleepGuardFailure("This connection doesn’t own the keep-awake session.")
        }
        guard let process, process.isRunning, let input, let output else {
            owner = nil
            throw SleepGuardFailure("The keep-awake session ended. Click the coffee cup to start again.")
        }
        do {
            try input.write(contentsOf: Data("\(ProcessInfo.processInfo.systemUptime)\n".utf8))
            try awaitReply(reader: output, expected: "ALIVE", timeout: 2)
        } catch {
            owner = nil
            try finishPreviousProcess()
            try recoverAfterRestart()
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
        try writer.close()
        defer { try? reader.close() }
        try awaitReply(reader: reader, expected: "READY", timeout: 4)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !child.isRunning else { throw SleepGuardFailure("Sleep recovery hasn’t finished yet.") }
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw SleepGuardFailure("Normal sleep couldn’t be restored.") }
    }

    private func finishPreviousProcess() throws {
        try input?.close()
        input = nil
        try? output?.close()
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
        self.process = nil
    }

    private func launch(mode: String) throws -> (Process, FileHandle, FileHandle) {
        let child = Process()
        let lease = Pipe()
        let response = Pipe()
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
        try lease.fileHandleForReading.close()
        try response.fileHandleForWriting.close()
        return (child, lease.fileHandleForWriting, response.fileHandleForReading)
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
                    guard line == expected else { throw SleepGuardFailure(line) }
                    return
                }
                if count == 0 { break }
            }
        }
        throw SleepGuardFailure("The keep-awake watchdog didn’t respond. Please try again.")
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
    var acknowledged = false
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
        acknowledged = true
        while ProcessInfo.processInfo.systemUptime < lastPulse + SleepGuardService.leaseDuration {
            descriptor.revents = 0
            let result = poll(&descriptor, 1, 200)
            guard result >= 0 || errno == EINTR else { break }
            try controller.tick()
            if result > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { break }
                let now = ProcessInfo.processInfo.systemUptime
                let stamps = String(decoding: buffer.prefix(count), as: UTF8.self)
                    .split(separator: "\n").compactMap { TimeInterval($0) }
                guard let latest = stamps.max(), latest > lastPulse,
                      latest <= now, now - latest < SleepGuardService.leaseDuration else { break }
                // Timestamp the lease at send time, so buffered renewals cannot
                // keep an abandoned session alive when the daemon is stalled.
                try controller.renew(session: session)
                try FileHandle.standardOutput.write(contentsOf: Data("ALIVE\n".utf8))
                lastPulse = latest
            }
        }
    } catch {
        logger.error("Watchdog lease ended: \(error.localizedDescription, privacy: .public)")
        if !acknowledged {
            try? FileHandle.standardOutput.write(contentsOf: Data("ERROR: \(error.localizedDescription)\n".utf8))
        }
    }
    if idleSleepHelper.isRunning { idleSleepHelper.terminate() }
    // Retry even after the UI and daemon are gone; keep the journal locked so
    // an old cleanup can never disable a newly enabled session.
    while true {
        do { try controller.shutdown(); return }
        catch {
            logger.error("Watchdog recovery will retry: \(error.localizedDescription, privacy: .public)")
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
