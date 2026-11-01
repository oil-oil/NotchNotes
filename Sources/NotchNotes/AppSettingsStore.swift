import Combine
import CoreGraphics
import Foundation

enum TriggerMode: String, CaseIterable, Identifiable {
    case hover
    case click
    case menuBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover:
            return "Hover"
        case .click:
            return "Click"
        case .menuBar:
            return "Menu Bar Only"
        }
    }

    var systemImage: String {
        switch self {
        case .hover:
            return "cursorarrow.motionlines"
        case .click:
            return "cursorarrow.click.2"
        case .menuBar:
            return "menubar.rectangle"
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
    @Published var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            if let selectedDisplayID {
                defaults.set(Int(selectedDisplayID), forKey: Self.selectedDisplayIDKey)
            } else {
                defaults.removeObject(forKey: Self.selectedDisplayIDKey)
            }
        }
    }
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var isChangingKeepAwake = false
    @Published private(set) var keepAwakeErrorMessage: String?
    @Published private(set) var keepAwakeNeedsApproval = false

    private static let triggerModeKey = "notchNotes.triggerMode"
    private static let selectedDisplayIDKey = "notchNotes.selectedDisplayID"
    private static let ownsSleepDisabledKey = "notchNotes.ownsSleepDisabled"
    private static let completedSleepGuardMigrationKey = "notchNotes.completedPrivilegedSleepGuardMigrationV1"
    private let defaults: UserDefaults
    private let systemSleepGuard: any SystemSleepGuardControlling
    private let sleepDisabledState: () -> Bool
    private var keepAwakeTask: Task<Void, Never>?
    private var needsSleepRecoveryAfterLaunch = false
    private var needsLegacySleepRecovery = false

    init(
        defaults: UserDefaults = .standard,
        systemSleepGuard: (any SystemSleepGuardControlling)? = nil,
        sleepDisabledState: (() -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.systemSleepGuard = systemSleepGuard ?? SystemSleepGuard()
        self.sleepDisabledState = sleepDisabledState ?? { SystemSleepGuard.isSleepDisabled() }

        let rawMode = defaults.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover
        selectedDisplayID = (defaults.object(forKey: Self.selectedDisplayIDKey) as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }

        let needsOwnedStateRecovery = defaults.bool(forKey: Self.ownsSleepDisabledKey)
        needsLegacySleepRecovery = needsOwnedStateRecovery
            && !defaults.bool(forKey: Self.completedSleepGuardMigrationKey)

        if needsOwnedStateRecovery {
            isKeepingAwake = self.sleepDisabledState()
            needsSleepRecoveryAfterLaunch = true
        } else {
            defaults.set(true, forKey: Self.completedSleepGuardMigrationKey)
            defaults.set(false, forKey: Self.ownsSleepDisabledKey)
        }
        self.systemSleepGuard.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            self.stopKeepingAwake()
            self.keepAwakeErrorMessage = "The keep-awake helper disconnected. The session has ended and normal sleep is being restored."
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

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let didStop = await self.systemSleepGuard.resetSleepIfNeeded(includingLegacyState: self.needsLegacySleepRecovery)
            guard !Task.isCancelled else { return }

            if didStop {
                self.needsLegacySleepRecovery = false
                self.defaults.set(true, forKey: Self.completedSleepGuardMigrationKey)
            }

            let remainsDisabled = !didStop && self.sleepDisabledState()
            self.setOwnsSleepDisabled(remainsDisabled)
            self.isKeepingAwake = remainsDisabled
            self.isChangingKeepAwake = false
            if !didStop {
                self.reportSleepRecoveryFailure()
            }
            self.keepAwakeTask = nil
        }
    }

    func dismissKeepAwakeError() {
        keepAwakeErrorMessage = nil
        keepAwakeNeedsApproval = false
    }

    func openKeepAwakeApprovalSettings() {
        dismissKeepAwakeError()
        SystemSleepGuard.openApprovalSettings()
    }

    private func requestKeepAwake() {
        guard !systemSleepGuard.isRunning else { return }

        isChangingKeepAwake = true
        keepAwakeErrorMessage = nil
        keepAwakeNeedsApproval = false

        do {
            try systemSleepGuard.start()
        } catch {
            setOwnsSleepDisabled(false)
            isChangingKeepAwake = false
            if let guardError = error as? SystemSleepGuardError {
                keepAwakeNeedsApproval = guardError == .approvalRequired
                keepAwakeErrorMessage = guardError.userMessage
            } else {
                keepAwakeErrorMessage = error.localizedDescription
            }
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.systemSleepGuard.waitUntilReady()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                _ = await self.systemSleepGuard.resetSleepIfNeeded()
                guard !Task.isCancelled else { return }
                self.setOwnsSleepDisabled(false)
                self.isKeepingAwake = false
                self.isChangingKeepAwake = false
                if let sleepGuardError = error as? SystemSleepGuardError {
                    self.keepAwakeNeedsApproval = sleepGuardError == .approvalRequired
                    self.keepAwakeErrorMessage = sleepGuardError.userMessage
                } else {
                    self.keepAwakeErrorMessage = error.localizedDescription
                }
                self.keepAwakeTask = nil
                return
            }

            guard !Task.isCancelled else { return }

            self.setOwnsSleepDisabled(true)

            self.isKeepingAwake = true
            self.isChangingKeepAwake = false
            self.keepAwakeTask = nil
        }
    }

    private func recoverSleepAfterUnexpectedExit() async {
        let didReset = await systemSleepGuard.resetSleepIfNeeded(includingLegacyState: needsLegacySleepRecovery)
        guard !Task.isCancelled else { return }

        let remainsDisabled = !didReset && sleepDisabledState()
        setOwnsSleepDisabled(remainsDisabled)
        if didReset {
            needsLegacySleepRecovery = false
            defaults.set(true, forKey: Self.completedSleepGuardMigrationKey)
        }
        isKeepingAwake = remainsDisabled
        isChangingKeepAwake = false
        if !didReset {
            reportSleepRecoveryFailure()
        }
        keepAwakeTask = nil
    }

    private func setOwnsSleepDisabled(_ ownsSleepDisabled: Bool) {
        defaults.set(ownsSleepDisabled, forKey: Self.ownsSleepDisabledKey)
    }

    private func reportSleepRecoveryFailure() {
        keepAwakeNeedsApproval = systemSleepGuard.requiresApproval
        keepAwakeErrorMessage = keepAwakeNeedsApproval
            ? "Allow NotchNotes in System Settings → General → Login Items & Extensions so its helper can restore normal sleep."
            : "Normal sleep couldn’t be restored yet. The background helper will keep trying."
    }
}
