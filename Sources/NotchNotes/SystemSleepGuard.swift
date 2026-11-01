import Foundation
import ServiceManagement
import SleepGuardCore

enum SystemSleepGuardError: Error, Equatable {
    case approvalRequired
    case notPackaged
    case helperLaunchFailed(String)
    case stateVerificationFailed

    var userMessage: String? {
        switch self {
        case .approvalRequired:
            return "To keep your Mac awake with the lid closed, allow NotchNotes in System Settings → General → Login Items & Extensions. This is only required once. Then click the coffee cup again."
        case .notPackaged:
            return "Run NotchNotes from the Applications folder to use closed-lid keep-awake mode. The packaged app includes the required background helper."
        case .helperLaunchFailed(let message): return message
        case .stateVerificationFailed:
            return "macOS didn’t enable closed-lid keep-awake mode. Please try again."
        }
    }
}

@MainActor
protocol SystemSleepGuardControlling: AnyObject {
    var isRunning: Bool { get }
    var requiresApproval: Bool { get }
    var onUnexpectedStop: (() -> Void)? { get set }
    func start() throws
    func waitUntilReady() async throws
    func requestStop()
    func resetSleepIfNeeded(includingLegacyState: Bool) async -> Bool
}

extension SystemSleepGuardControlling {
    func resetSleepIfNeeded() async -> Bool {
        await resetSleepIfNeeded(includingLegacyState: false)
    }
}

@MainActor
final class SystemSleepGuard: SystemSleepGuardControlling {
    var onUnexpectedStop: (() -> Void)?
    private(set) var requiresApproval = false
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var isActive = false

    var isRunning: Bool { connectionID != nil }

    func start() throws {
        guard !isRunning else { return }
        try validateBundle()
        connectionID = UUID()
    }

    func waitUntilReady() async throws {
        guard let id = connectionID else {
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper isn’t connected.")
        }
        try await ensureServiceIsEnabled()
        try Task.checkCancellation()
        guard connectionID == id else {
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake session was stopped while starting.")
        }
        let connection = try makeConnection()
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connectionEnded(id: id) }
        }
        connection.interruptionHandler = connection.invalidationHandler
        self.connection = connection
        connection.resume()
        try await send(.begin, over: connection)
        try Task.checkCancellation()
        guard connectionID == id else {
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper disconnected while starting. Please try again.")
        }
        guard Self.isSleepDisabled() else { throw SystemSleepGuardError.stateVerificationFailed }
        isActive = true
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                    guard let self, self.connectionID == id else { return }
                    try await self.send(.renew, over: connection)
                } catch is CancellationError {
                    return
                } catch {
                    self?.connectionEnded(id: id)
                    return
                }
            }
        }
    }

    func requestStop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        isActive = false
        connectionID = nil
        let previous = connection
        connection = nil
        // Invalidation is delivered even if the UI app immediately exits or is
        // SIGKILLed. The daemon restores sleep without waiting for app cleanup.
        previous?.invalidate()
    }

    func resetSleepIfNeeded(includingLegacyState: Bool) async -> Bool {
        requestStop()
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if (try? SystemSleepPower().isSleepDisabled()) == false { return true }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        } while ContinuousClock.now < deadline

        guard !Task.isCancelled else { return false }
        // Also migrates a persistent disablesleep flag left by older app builds.
        do {
            try await ensureServiceIsEnabled()
            let recoveryConnection = try makeConnection()
            recoveryConnection.resume()
            defer { recoveryConnection.invalidate() }
            try await send(includingLegacyState ? .recoverLegacy : .recoverOwned, over: recoveryConnection)
            return true
        } catch {
            return false
        }
    }

    static func isSleepDisabled() -> Bool {
        (try? SystemSleepPower().isSleepDisabled()) == true
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(SleepGuardService.helperName)")
    }

    private func validateBundle() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: helperURL.path),
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(SleepGuardService.plistName)").path),
              Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications" else {
            throw SystemSleepGuardError.notPackaged
        }
    }

    private func ensureServiceIsEnabled() async throws {
        requiresApproval = false
        try validateBundle()
        let service = SMAppService.daemon(plistName: SleepGuardService.plistName)
        let buildKey = "notchNotes.registeredSleepHelperBuild"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if service.status == .enabled, UserDefaults.standard.string(forKey: buildKey) != build {
            // launchd caches helper metadata; updating a bundle alone doesn't
            // replace a running daemon. Wait for unregister before registering.
            try await service.unregister()
            try Task.checkCancellation()
        }
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                if service.status == .requiresApproval {
                    UserDefaults.standard.set(build, forKey: buildKey)
                    requiresApproval = true
                    throw SystemSleepGuardError.approvalRequired
                }
                throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper couldn’t be registered. \(error.localizedDescription)")
            }
        }
        switch service.status {
        case .enabled:
            UserDefaults.standard.set(build, forKey: buildKey)
            return
        case .requiresApproval:
            UserDefaults.standard.set(build, forKey: buildKey)
            requiresApproval = true
            throw SystemSleepGuardError.approvalRequired
        default:
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper is unavailable. Reinstall NotchNotes in Applications and try again.")
        }
    }

    private func makeConnection() throws -> NSXPCConnection {
        let requirement = try SleepGuardService.signingRequirement(for: helperURL)
        let connection = NSXPCConnection(machServiceName: SleepGuardService.identifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepGuardXPC.self)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    private func connectionEnded(id: UUID) {
        guard connectionID == id else { return }
        let wasActive = isActive
        requestStop()
        if wasActive { onUnexpectedStop?() }
    }

    private enum Operation { case begin, renew, recoverOwned, recoverLegacy }

    private func send(_ operation: Operation, over connection: NSXPCConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                let message = error.localizedDescription
                Task { @MainActor in pending.finish(.failure(SleepGuardFailure(message))) }
            } as? SleepGuardXPC
            guard let proxy else {
                pending.finish(.failure(SleepGuardFailure("The keep-awake helper couldn’t be reached.")))
                return
            }
            let reply: @Sendable (Bool, String?) -> Void = { success, message in
                Task { @MainActor in
                    pending.finish(success ? .success(()) : .failure(SleepGuardFailure(message ?? "The keep-awake session ended.")))
                }
            }
            switch operation {
            case .begin: proxy.begin(withReply: reply)
            case .renew: proxy.renew(withReply: reply)
            case .recoverOwned: proxy.recoverOwnedSleep(withReply: reply)
            case .recoverLegacy: proxy.recoverLegacySleep(withReply: reply)
            }
        }
    }
}

@MainActor
private final class PendingReply {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            self?.finish(.failure(SleepGuardFailure("The keep-awake helper didn’t respond. Please try again.")))
        }
    }

    func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
