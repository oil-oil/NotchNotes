import Foundation

public protocol SleepPowerControlling {
    func isSleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
}

public protocol SleepOwnershipStoring {
    func isOwned() throws -> Bool
    func setOwned(_ owned: Bool) throws
}

// All access is serialized by the daemon. The journal is durable before enabling
// sleep prevention, so launchd can recover even after SIGKILL or a power loss.
public final class SleepLeaseController {
    private let power: any SleepPowerControlling
    private let ownership: any SleepOwnershipStoring
    private let now: () -> TimeInterval
    private let leaseDuration: TimeInterval
    private var owner: UUID?
    private var deadline: TimeInterval = 0

    public init(
        power: any SleepPowerControlling,
        ownership: any SleepOwnershipStoring,
        leaseDuration: TimeInterval = SleepGuardService.leaseDuration,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.power = power
        self.ownership = ownership
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func recoverAfterRestart() throws {
        owner = nil
        try restoreIfOwned()
    }

    public func begin(session: UUID) throws {
        try tick()
        guard owner == nil || owner == session else {
            throw SleepGuardFailure("Another NotchNotes window is already keeping this Mac awake.")
        }
        if owner == session {
            try renew(session: session)
            return
        }
        guard try !power.isSleepDisabled() else {
            throw SleepGuardFailure("Sleep is already disabled by another process. Restore normal sleep before enabling this mode.")
        }
        try ownership.setOwned(true)
        do {
            try power.setSleepDisabled(true)
            guard try power.isSleepDisabled() else {
                throw SleepGuardFailure("macOS didn’t enable closed-lid keep-awake mode.")
            }
            owner = session
            deadline = now() + leaseDuration
        } catch {
            try? restoreIfOwned()
            throw error
        }
    }

    public func renew(session: UUID) throws {
        try tick()
        guard owner == session else {
            throw SleepGuardFailure("The keep-awake session ended. Click the coffee cup to start again.")
        }
        guard try power.isSleepDisabled() else {
            try end(session: session)
            throw SleepGuardFailure("macOS ended the keep-awake session.")
        }
        deadline = now() + leaseDuration
    }

    public func end(session: UUID) throws {
        guard owner == session else { return }
        owner = nil
        try restoreIfOwned()
    }

    public func recoverLegacySleep() throws {
        try tick()
        guard owner == nil else {
            throw SleepGuardFailure("A keep-awake session is still active.")
        }
        // Only an authenticated app may request recovery of pre-helper versions.
        if try power.isSleepDisabled() { try ownership.setOwned(true) }
        try restoreIfOwned()
    }

    public func tick() throws {
        if owner != nil, now() >= deadline { owner = nil }
        if owner == nil { try restoreIfOwned() }
    }

    public func shutdown() throws {
        owner = nil
        try restoreIfOwned()
    }

    private func restoreIfOwned() throws {
        guard try ownership.isOwned() else { return }
        try power.setSleepDisabled(false)
        guard try !power.isSleepDisabled() else {
            throw SleepGuardFailure("macOS hasn’t restored normal sleep yet. The helper will retry.")
        }
        // Keep the recovery marker until the OS confirms sleep is restored.
        try ownership.setOwned(false)
    }
}
