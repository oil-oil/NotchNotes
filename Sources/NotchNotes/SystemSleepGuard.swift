import Foundation
import ServiceManagement
import SleepGuardCore

enum SystemSleepGuardError: Error, Equatable {
    case approvalRequired
    case notPackaged
    case helperLaunchFailed(String)
    case stateVerificationFailed

    var userMessage: String? {
        userMessage(for: .english)
    }

    func userMessage(for language: AppLanguage = .english) -> String? {
        AppStrings(language: language).sleepGuardErrorMessage(self)
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
protocol SleepDaemonServiceManaging: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

private final class SystemDaemonServiceAdapter: SleepDaemonServiceManaging {
    private let service: SMAppService

    init(plistName: String = SleepGuardService.plistName) {
        self.service = SMAppService.daemon(plistName: plistName)
    }

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

private enum SleepGuardXPCOperation: Sendable {
    case begin
    case renew
    case recoverOwned
    case recoverLegacy
}

// Keep NSXPCConnection block callbacks outside @MainActor so Swift 6 does not
// attach a main-queue isolation assertion when XPC invokes them on its private queue.
private enum SleepGuardXPCBridge {
    static func configureHandlers(
        on connection: NSXPCConnection,
        onDisconnect: @escaping @MainActor @Sendable () -> Void
    ) {
        connection.invalidationHandler = {
            Task { @MainActor in
                onDisconnect()
            }
        }
        connection.interruptionHandler = {
            Task { @MainActor in
                onDisconnect()
            }
        }
    }

    static func send(
        _ operation: SleepGuardXPCOperation,
        over connection: NSXPCConnection,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let message = error.localizedDescription
            Task { @MainActor in
                completion(.failure(SleepGuardFailure(message)))
            }
        } as? SleepGuardXPC

        guard let proxy else {
            Task { @MainActor in
                completion(.failure(SleepGuardFailure("The keep-awake helper couldn’t be reached.")))
            }
            return
        }

        let reply: @Sendable (Bool, String?) -> Void = { success, message in
            let result: Result<Void, Error> = success
                ? .success(())
                : .failure(SleepGuardFailure(message ?? "The keep-awake session ended."))
            Task { @MainActor in
                completion(result)
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

@MainActor
final class SystemSleepGuard: SystemSleepGuardControlling {
    var onUnexpectedStop: (() -> Void)?
    private(set) var requiresApproval = false
    private let defaults: UserDefaults
    private let serviceFactory: @MainActor () -> any SleepDaemonServiceManaging
    private let registrationSignatureProvider: () throws -> String
    private let bundleValidator: () throws -> Void
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var isActive = false

    private static let registeredSignatureKey = "notchNotes.registeredSleepHelperSignature"

    var isRunning: Bool { connectionID != nil }

    init(
        defaults: UserDefaults = .standard,
        serviceFactory: (@MainActor () -> any SleepDaemonServiceManaging)? = nil,
        registrationSignatureProvider: (() throws -> String)? = nil,
        bundleValidator: (() throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.serviceFactory = serviceFactory ?? { SystemDaemonServiceAdapter() }
        self.registrationSignatureProvider = registrationSignatureProvider ?? {
            try Self.currentRegistrationSignature()
        }
        self.bundleValidator = bundleValidator ?? {
            try Self.validateMainBundle()
        }
    }

    func start() throws {
        guard !isRunning else { return }
        try bundleValidator()
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
        configureHandlers(on: connection, id: id)
        self.connection = connection
        connection.resume()
        try await send(.begin, over: connection)
        try Task.checkCancellation()
        guard connectionID == id else {
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper disconnected while starting. Please try again.")
        }
        guard await Self.asyncIsSleepDisabled() else { throw SystemSleepGuardError.stateVerificationFailed }
        try Task.checkCancellation()
        guard connectionID == id else {
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper disconnected while starting. Please try again.")
        }
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

    func configureConnectionForTesting(_ connection: NSXPCConnection, id: UUID = UUID(), markActive: Bool = false) {
        connectionID = id
        isActive = markActive
        configureHandlers(on: connection, id: id)
        self.connection = connection
        connection.resume()
    }

    func sendBeginForTesting(over connection: NSXPCConnection) async throws {
        try await send(.begin, over: connection)
    }

    func ensureServiceIsEnabledForTesting() async throws {
        try await ensureServiceIsEnabled()
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
            let isDisabled = await Self.asyncIsSleepDisabled()
            guard !Task.isCancelled else { return false }
            if !isDisabled { return true }
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

    nonisolated static func isSleepDisabled() -> Bool {
        (try? SystemSleepPower().isSleepDisabled()) == true
    }

    private static func asyncIsSleepDisabled() async -> Bool {
        await Task.detached(priority: .utility) {
            isSleepDisabled()
        }.value
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var defaultHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(SleepGuardService.helperName)")
    }

    private static func validateMainBundle() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: defaultHelperURL.path),
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(SleepGuardService.plistName)").path),
              Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications" else {
            throw SystemSleepGuardError.notPackaged
        }
    }

    private static func currentRegistrationSignature(
        bundle: Bundle = .main
    ) throws -> String {
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let appRequirement = try SleepGuardService.signingRequirement(
            for: bundle.bundleURL,
            expectedIdentifier: SleepGuardService.appIdentifier
        )
        let helperRequirement = try SleepGuardService.signingRequirement(
            for: defaultHelperURL,
            expectedIdentifier: SleepGuardService.identifier
        )
        return "\(build)\n\(appRequirement)\n\(helperRequirement)"
    }

    private func ensureServiceIsEnabled() async throws {
        requiresApproval = false
        try bundleValidator()
        let service = serviceFactory()
        let signature = try registrationSignatureProvider()
        if service.status == .enabled, defaults.string(forKey: Self.registeredSignatureKey) != signature {
            // launchd caches helper metadata and ad-hoc rebuilds change cdhash even
            // when CFBundleVersion is unchanged; unregister so register loads the new helper.
            try await service.unregister()
            try Task.checkCancellation()
        }
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                if service.status == .requiresApproval {
                    defaults.set(signature, forKey: Self.registeredSignatureKey)
                    requiresApproval = true
                    throw SystemSleepGuardError.approvalRequired
                }
                throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper couldn’t be registered. \(error.localizedDescription)")
            }
        }
        switch service.status {
        case .enabled:
            defaults.set(signature, forKey: Self.registeredSignatureKey)
            return
        case .requiresApproval:
            defaults.set(signature, forKey: Self.registeredSignatureKey)
            requiresApproval = true
            throw SystemSleepGuardError.approvalRequired
        default:
            throw SystemSleepGuardError.helperLaunchFailed("The keep-awake helper is unavailable. Reinstall NotchNotes in Applications and try again.")
        }
    }

    private func makeConnection() throws -> NSXPCConnection {
        let requirement = try SleepGuardService.signingRequirement(for: Self.defaultHelperURL)
        let connection = NSXPCConnection(machServiceName: SleepGuardService.identifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepGuardXPC.self)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    private func configureHandlers(on connection: NSXPCConnection, id: UUID) {
        SleepGuardXPCBridge.configureHandlers(on: connection) { [weak self] in
            self?.connectionEnded(id: id)
        }
    }

    private func connectionEnded(id: UUID) {
        guard connectionID == id else { return }
        let wasActive = isActive
        requestStop()
        if wasActive { onUnexpectedStop?() }
    }

    private func send(_ operation: SleepGuardXPCOperation, over connection: NSXPCConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation)
            SleepGuardXPCBridge.send(operation, over: connection) { result in
                pending.finish(result)
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
