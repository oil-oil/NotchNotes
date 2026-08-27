import Combine
import Foundation

enum TriggerMode: String, CaseIterable, Identifiable {
    case hover
    case click

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover:
            return "Hover"
        case .click:
            return "Click"
        }
    }

    var systemImage: String {
        switch self {
        case .hover:
            return "cursorarrow.motionlines"
        case .click:
            return "cursorarrow.click.2"
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var triggerMode: TriggerMode {
        didSet {
            defaults.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var isChangingKeepAwake = false
    @Published private(set) var keepAwakeErrorMessage: String?

    private static let triggerModeKey = "notchNotes.triggerMode"
    private static let ownsSleepDisabledKey = "notchNotes.ownsSleepDisabled"
    private static let completedSleepGuardMigrationKey = "notchNotes.completedSleepGuardRecoveryV1"
    private let defaults: UserDefaults
    private let systemSleepGuard: any SystemSleepGuardControlling
    private let sleepDisabledState: () -> Bool
    private let caffeinateLauncher: () -> Process?
    private var caffeinateProcess: Process?
    private var keepAwakeTask: Task<Void, Never>?
    private var needsSleepRecoveryAfterLaunch = false

    init(
        defaults: UserDefaults = .standard,
        systemSleepGuard: (any SystemSleepGuardControlling)? = nil,
        sleepDisabledState: (() -> Bool)? = nil,
        caffeinateLauncher: (() -> Process?)? = nil
    ) {
        self.defaults = defaults
        self.systemSleepGuard = systemSleepGuard ?? SystemSleepGuard()
        self.sleepDisabledState = sleepDisabledState ?? { SystemSleepGuard.isSleepDisabled() }
        self.caffeinateLauncher = caffeinateLauncher ?? Self.launchCaffeinate

        let rawMode = defaults.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover

        let needsOwnedStateRecovery = defaults.bool(forKey: Self.ownsSleepDisabledKey)
        let needsLegacyRecovery = !defaults.bool(forKey: Self.completedSleepGuardMigrationKey)
            && self.sleepDisabledState()

        if needsOwnedStateRecovery || needsLegacyRecovery {
            isKeepingAwake = self.sleepDisabledState()
            needsSleepRecoveryAfterLaunch = true
        } else {
            defaults.set(true, forKey: Self.completedSleepGuardMigrationKey)
            defaults.set(false, forKey: Self.ownsSleepDisabledKey)
        }
    }

    func recoverSleepAfterLaunchIfNeeded() {
        guard needsSleepRecoveryAfterLaunch, keepAwakeTask == nil else { return }

        needsSleepRecoveryAfterLaunch = false
        isChangingKeepAwake = true
        keepAwakeTask = Task { [weak self] in
            await self?.recoverSleepAfterUnexpectedExit()
        }
    }

    func toggleKeepAwake() {
        guard !isChangingKeepAwake else { return }

        if isKeepingAwake {
            stopKeepingAwake()
        } else {
            requestKeepAwake()
        }
    }

    func stopKeepingAwake() {
        keepAwakeTask?.cancel()
        keepAwakeTask = nil
        systemSleepGuard.requestStop()
        isChangingKeepAwake = true

        let process = caffeinateProcess
        caffeinateProcess = nil

        if let process, process.isRunning {
            process.terminate()
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let didStop = await self.systemSleepGuard.resetSleepIfNeeded()
            guard !Task.isCancelled else { return }

            let remainsDisabled = !didStop && self.sleepDisabledState()
            self.setOwnsSleepDisabled(remainsDisabled)
            self.isKeepingAwake = remainsDisabled
            self.isChangingKeepAwake = false
            if !didStop {
                self.keepAwakeErrorMessage = "Administrator permission is required to restore normal sleep."
            }
            self.keepAwakeTask = nil
        }
    }

    func dismissKeepAwakeError() {
        keepAwakeErrorMessage = nil
    }

    private func requestKeepAwake() {
        guard caffeinateProcess == nil, !systemSleepGuard.isRunning else { return }

        isChangingKeepAwake = true
        keepAwakeErrorMessage = nil

        do {
            try systemSleepGuard.start()
        } catch {
            setOwnsSleepDisabled(false)
            isChangingKeepAwake = false
            keepAwakeErrorMessage = "The macOS authorization prompt couldn’t open. Please try again."
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.systemSleepGuard.waitUntilReady()
            } catch is CancellationError {
                return
            } catch {
                let didReset = await self.systemSleepGuard.resetSleepIfNeeded()
                let remainsDisabled = !didReset && self.sleepDisabledState()
                self.setOwnsSleepDisabled(remainsDisabled)
                self.isKeepingAwake = remainsDisabled
                self.isChangingKeepAwake = false
                if let sleepGuardError = error as? SystemSleepGuardError {
                    self.keepAwakeErrorMessage = sleepGuardError.userMessage
                } else {
                    self.keepAwakeErrorMessage = "The keep-awake helper couldn’t start. Please try again."
                }
                self.keepAwakeTask = nil
                return
            }

            guard !Task.isCancelled else { return }

            self.setOwnsSleepDisabled(true)

            guard self.startCaffeinate() else {
                let didReset = await self.systemSleepGuard.resetSleepIfNeeded()
                let remainsDisabled = !didReset && self.sleepDisabledState()
                self.setOwnsSleepDisabled(remainsDisabled)
                self.isKeepingAwake = remainsDisabled
                self.isChangingKeepAwake = false
                self.keepAwakeErrorMessage = "macOS enabled closed-lid mode, but the idle-sleep helper couldn’t start."
                self.keepAwakeTask = nil
                return
            }

            self.isKeepingAwake = true
            self.isChangingKeepAwake = false
            self.keepAwakeTask = nil
        }
    }

    private func startCaffeinate() -> Bool {
        guard caffeinateProcess == nil else { return true }

        guard let process = caffeinateLauncher() else {
            return false
        }

        caffeinateProcess = process
        return true
    }

    private static func launchCaffeinate() -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [
            "-dims",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    private func recoverSleepAfterUnexpectedExit() async {
        let didReset = await systemSleepGuard.resetSleepIfNeeded()
        guard !Task.isCancelled else { return }

        let remainsDisabled = !didReset && sleepDisabledState()
        setOwnsSleepDisabled(remainsDisabled)
        if didReset {
            defaults.set(true, forKey: Self.completedSleepGuardMigrationKey)
        }
        isKeepingAwake = remainsDisabled
        isChangingKeepAwake = false
        if !didReset {
            keepAwakeErrorMessage = "Administrator permission is required to restore normal sleep."
        }
        keepAwakeTask = nil
    }

    private func setOwnsSleepDisabled(_ ownsSleepDisabled: Bool) {
        defaults.set(ownsSleepDisabled, forKey: Self.ownsSleepDisabledKey)
    }
}
