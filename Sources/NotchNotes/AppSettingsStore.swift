import AppKit
import Combine
import CoreGraphics
import Foundation

enum TriggerMode: String, CaseIterable, Identifiable {
    case hover
    case click
    case menuBar

    var id: String { rawValue }

    var title: String {
        title(for: .english)
    }

    func title(for language: AppLanguage) -> String {
        AppStrings(language: language).triggerModeTitle(self)
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
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
        }
    }
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var isChangingKeepAwake = false
    @Published private(set) var keepAwakeErrorMessage: String?
    @Published private(set) var keepAwakeNeedsApproval = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var launchAtLoginErrorMessage: String?
    @Published private(set) var launchAtLoginNeedsApproval = false

    private static let triggerModeKey = "notchNotes.triggerMode"
    private static let selectedDisplayIDKey = "notchNotes.selectedDisplayID"
    private static let languageKey = "notchNotes.language"
    private static let ownsSleepDisabledKey = "notchNotes.ownsSleepDisabled"
    private static let completedSleepGuardMigrationKey = "notchNotes.completedPrivilegedSleepGuardMigrationV1"
    private let defaults: UserDefaults
    private let systemSleepGuard: any SystemSleepGuardControlling
    private let sleepDisabledState: () -> Bool
    private let launchAtLoginController: any LaunchAtLoginControlling
    private var keepAwakeTask: Task<Void, Never>?
    private var applicationDidBecomeActiveCancellable: AnyCancellable?
    private var needsSleepRecoveryAfterLaunch = false
    private var needsLegacySleepRecovery = false

    var strings: AppStrings {
        AppStrings(language: language)
    }

    var canConfigureLaunchAtLogin: Bool {
        launchAtLoginController.canConfigure
    }

    init(
        defaults: UserDefaults = .standard,
        systemSleepGuard: (any SystemSleepGuardControlling)? = nil,
        sleepDisabledState: (() -> Bool)? = nil,
        launchAtLoginController: (any LaunchAtLoginControlling)? = nil,
        preferredLanguages: [String] = Bundle.main.bundleURL.pathExtension == "app"
            ? Locale.preferredLanguages
            : ["en"]
    ) {
        self.defaults = defaults
        self.systemSleepGuard = systemSleepGuard ?? SystemSleepGuard()
        self.sleepDisabledState = sleepDisabledState ?? { SystemSleepGuard.isSleepDisabled() }
        self.launchAtLoginController = launchAtLoginController ?? LaunchAtLoginController()

        let rawMode = defaults.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover
        selectedDisplayID = (defaults.object(forKey: Self.selectedDisplayIDKey) as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
        language = defaults.string(forKey: Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.defaultLanguage(forPreferredLanguages: preferredLanguages)

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
            self.keepAwakeErrorMessage = self.strings.keepAwakeDisconnectedMessage
        }
        refreshLaunchAtLoginState()
        applicationDidBecomeActiveCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.refreshLaunchAtLoginState()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.refreshLaunchAtLoginState()
                    }
                }
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
        let wasIdle = keepAwakeTask == nil
            && !isKeepingAwake
            && !isChangingKeepAwake
            && !systemSleepGuard.isRunning
            && !defaults.bool(forKey: Self.ownsSleepDisabledKey)
            && !needsLegacySleepRecovery
            && !needsSleepRecoveryAfterLaunch
        if wasIdle {
            return
        }

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

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        dismissLaunchAtLoginError()

        guard canConfigureLaunchAtLogin else {
            isLaunchAtLoginEnabled = false
            if enabled {
                launchAtLoginErrorMessage = LaunchAtLoginError.notPackaged.userMessage(for: language)
            }
            return
        }

        do {
            if enabled {
                try launchAtLoginController.register()
            } else {
                try launchAtLoginController.unregister()
            }
        } catch {
            refreshLaunchAtLoginState()
            if let launchError = error as? LaunchAtLoginError {
                launchAtLoginNeedsApproval = launchError == .approvalRequired
                launchAtLoginErrorMessage = launchError.userMessage(for: language)
            } else {
                launchAtLoginNeedsApproval = launchAtLoginController.status == .requiresApproval
                launchAtLoginErrorMessage = error.localizedDescription
            }
            return
        }

        refreshLaunchAtLoginState()
        if enabled, launchAtLoginController.status == .requiresApproval {
            launchAtLoginNeedsApproval = true
            launchAtLoginErrorMessage = LaunchAtLoginError.approvalRequired.userMessage(for: language)
        }
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLoginEnabled(!isLaunchAtLoginEnabled)
    }

    func refreshLaunchAtLoginState() {
        let status = launchAtLoginController.status
        let isEnabled = canConfigureLaunchAtLogin && status.isEnabled
        if isLaunchAtLoginEnabled != isEnabled {
            isLaunchAtLoginEnabled = isEnabled
        }
        if isEnabled, launchAtLoginNeedsApproval {
            dismissLaunchAtLoginError()
        }
    }

    func dismissLaunchAtLoginError() {
        launchAtLoginErrorMessage = nil
        launchAtLoginNeedsApproval = false
    }

    func openLaunchAtLoginApprovalSettings() {
        dismissLaunchAtLoginError()
        launchAtLoginController.openApprovalSettings()
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
                keepAwakeErrorMessage = guardError.userMessage(for: language)
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
                    self.keepAwakeErrorMessage = sleepGuardError.userMessage(for: self.language)
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
            ? strings.sleepRecoveryNeedsApprovalMessage
            : strings.sleepRecoveryRetryingMessage
    }
}
