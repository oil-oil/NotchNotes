import Darwin
import Foundation
import OSLog
import SleepGuardCore

let logger = Logger(subsystem: SleepGuardService.identifier, category: "Recovery")

final class SleepDaemon: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: SleepGuardService.identifier)
    private let watchdog: WatchdogProcess
    private var signals: [DispatchSourceSignal] = []
    private var recoveryTimer: DispatchSourceTimer?

    init(watchdog: WatchdogProcess) { self.watchdog = watchdog }

    func start() throws {
        try queue.sync { try watchdog.recoverAfterRestart() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in
            do { try watchdog.recoverIfWorkerExited() }
            catch { logger.error("Worker recovery will retry: \(error.localizedDescription, privacy: .public)") }
        }
        timer.resume()
        recoveryTimer = timer
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [self] in
                do { try watchdog.shutdown() }
                catch { logger.error("Watchdog will finish recovery: \(error.localizedDescription, privacy: .public)") }
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signals.append(source)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        let session = SleepSession(daemon: self)
        connection.exportedInterface = NSXPCInterface(with: SleepGuardXPC.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [self, id = session.id] in
            queue.async { [self] in
                do { try watchdog.end(session: id) }
                catch { logger.error("Watchdog will finish recovery: \(error.localizedDescription, privacy: .public)") }
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }

    func perform(_ operation: Operation, session: UUID, reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [self] in
            do {
                switch operation {
                case .begin: try watchdog.begin(session: session)
                case .renew: try watchdog.renew(session: session)
                case .recover: try watchdog.recover()
                case .recoverOwned: try watchdog.recoverAfterRestart()
                }
                reply(true, nil)
            } catch {
                logger.error("Sleep operation failed: \(error.localizedDescription, privacy: .public)")
                reply(false, error.localizedDescription)
            }
        }
    }

    enum Operation: Sendable { case begin, renew, recover, recoverOwned }
}

private final class SleepSession: NSObject, SleepGuardXPC, @unchecked Sendable {
    let id = UUID()
    let daemon: SleepDaemon
    init(daemon: SleepDaemon) { self.daemon = daemon }

    func begin(withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        daemon.perform(.begin, session: id, reply: reply)
    }
    func renew(withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        daemon.perform(.renew, session: id, reply: reply)
    }
    func recoverLegacySleep(withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        daemon.perform(.recover, session: id, reply: reply)
    }
    func recoverOwnedSleep(withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        daemon.perform(.recoverOwned, session: id, reply: reply)
    }
}

do {
    guard geteuid() == 0 else { throw SleepGuardFailure("The sleep helper must be managed by launchd as root.") }
    signal(SIGPIPE, SIG_IGN)
    let journal = try OwnershipJournal()
    if CommandLine.arguments.count == 2, ["--watchdog", "--recover", "--recover-owned"].contains(CommandLine.arguments[1]) {
        // The child is the only power-setting writer. It holds an exclusive lock
        // until recovery completes, including when its parent is stopped/killed.
        try journal.withExclusiveLock {
            try runWatchdog(journal: journal, mode: CommandLine.arguments[1])
        }
        exit(EXIT_SUCCESS)
    }
    guard CommandLine.arguments.count == 1 else { throw SleepGuardFailure("Invalid helper arguments.") }
    // PROC_PIDPATHINFO_MAXSIZE is a C macro unavailable to Swift.
    var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else {
        throw SleepGuardFailure("Couldn’t locate the installed sleep helper.")
    }
    let executable = URL(fileURLWithPath: String(decoding: path.prefix(while: { $0 != 0 }), as: UTF8.self)).resolvingSymlinksInPath()
    let protectedWorker: URL
    do { protectedWorker = try journal.protectedWorker(copying: executable) }
    catch {
        // An invalid app update must not block cleanup of an earlier session.
        try journal.withExclusiveLock {
            try SleepLeaseController(power: SystemSleepPower(), ownership: journal).recoverAfterRestart()
        }
        throw error
    }
    let daemon = SleepDaemon(watchdog: WatchdogProcess(executable: protectedWorker, journal: journal))
    try daemon.start()
    // Restore abandoned state before checking a potentially updated main app.
    let appBundle = executable.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let requirement = try SleepGuardService.signingRequirement(
        for: appBundle,
        expectedIdentifier: SleepGuardService.appIdentifier,
        sameSignerAs: executable
    )
    let listener = NSXPCListener(machServiceName: SleepGuardService.identifier)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = daemon
    listener.resume()
    dispatchMain()
} catch {
    logger.fault("Sleep helper failed: \(error.localizedDescription, privacy: .public)")
    try? FileHandle.standardOutput.write(contentsOf: Data("ERROR: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
