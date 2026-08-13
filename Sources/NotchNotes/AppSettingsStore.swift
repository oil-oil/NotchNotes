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
            UserDefaults.standard.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var isChangingKeepAwake = false
    @Published private(set) var keepAwakeErrorMessage: String?

    private static let triggerModeKey = "notchNotes.triggerMode"
    private static let ownsSleepDisabledKey = "notchNotes.ownsSleepDisabled"
    private static let completedSleepGuardMigrationKey = "notchNotes.completedSleepGuardRecoveryV1"
    private var caffeinateProcess: Process?
    private let systemSleepGuard = SystemSleepGuard()
    private var keepAwakeTask: Task<Void, Never>?

    init() {
        let rawMode = UserDefaults.standard.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover

        let defaults = UserDefaults.standard
        let needsOwnedStateRecovery = defaults.bool(forKey: Self.ownsSleepDisabledKey)
        let needsLegacyRecovery = !defaults.bool(forKey: Self.completedSleepGuardMigrationKey)
            && SystemSleepGuard.isSleepDisabled()

        if needsOwnedStateRecovery || needsLegacyRecovery {
            isKeepingAwake = SystemSleepGuard.isSleepDisabled()
            isChangingKeepAwake = true
            keepAwakeTask = Task { [weak self] in
                await self?.recoverSleepAfterUnexpectedExit()
            }
        } else {
            defaults.set(true, forKey: Self.completedSleepGuardMigrationKey)
            defaults.set(false, forKey: Self.ownsSleepDisabledKey)
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

            self.setOwnsSleepDisabled(!didStop)
            self.isKeepingAwake = !didStop && SystemSleepGuard.isSleepDisabled()
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
        setOwnsSleepDisabled(true)

        do {
            try systemSleepGuard.start()
        } catch {
            setOwnsSleepDisabled(false)
            isChangingKeepAwake = false
            keepAwakeErrorMessage = "Administrator permission is required to prevent sleep when the lid is closed."
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let isReady = await self.systemSleepGuard.waitUntilReady()
            guard !Task.isCancelled else { return }

            guard isReady, self.startCaffeinate() else {
                let didReset = await self.systemSleepGuard.resetSleepIfNeeded()
                self.setOwnsSleepDisabled(!didReset)
                self.isKeepingAwake = !didReset && SystemSleepGuard.isSleepDisabled()
                self.isChangingKeepAwake = false
                self.keepAwakeErrorMessage = "Administrator permission is required to prevent sleep when the lid is closed."
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [
            "-dims",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        do {
            try process.run()
            caffeinateProcess = process
            return true
        } catch {
            caffeinateProcess = nil
            return false
        }
    }

    private func recoverSleepAfterUnexpectedExit() async {
        let didReset = await systemSleepGuard.resetSleepIfNeeded()
        guard !Task.isCancelled else { return }

        setOwnsSleepDisabled(!didReset)
        if didReset {
            UserDefaults.standard.set(true, forKey: Self.completedSleepGuardMigrationKey)
        }
        isKeepingAwake = !didReset && SystemSleepGuard.isSleepDisabled()
        isChangingKeepAwake = false
        if !didReset {
            keepAwakeErrorMessage = "Administrator permission is required to restore normal sleep."
        }
        keepAwakeTask = nil
    }

    private func setOwnsSleepDisabled(_ ownsSleepDisabled: Bool) {
        UserDefaults.standard.set(ownsSleepDisabled, forKey: Self.ownsSleepDisabledKey)
    }
}
