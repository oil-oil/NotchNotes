import AppKit
import Foundation
import XCTest
@testable import NotchNotes

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testMenuBarOnlyModeSurvivesRestartAndCanBeChangedBack() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults, sleepDisabledState: { false })

        store.triggerMode = .menuBar
        let restored = AppSettingsStore(defaults: defaults, sleepDisabledState: { false })
        XCTAssertEqual(restored.triggerMode, .menuBar)

        restored.triggerMode = .hover
        let switchedBack = AppSettingsStore(defaults: defaults, sleepDisabledState: { false })
        XCTAssertEqual(switchedBack.triggerMode, .hover)
    }

    func testSelectedDisplayIDPersistsAndRestores() {
        let defaults = makeDefaults()
        defaults.set(1234, forKey: "notchNotes.selectedDisplayID")

        let store = AppSettingsStore(
            defaults: defaults,
            sleepDisabledState: { false }
        )

        XCTAssertEqual(store.selectedDisplayID, 1234)

        store.selectedDisplayID = 5678
        XCTAssertEqual(defaults.integer(forKey: "notchNotes.selectedDisplayID"), 5678)

        store.selectedDisplayID = nil
        XCTAssertNil(defaults.object(forKey: "notchNotes.selectedDisplayID"))
    }

    func testSleepRecoveryWaitsUntilApplicationIsVisible() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.completedSleepGuardRecoveryV1")
        defaults.set(true, forKey: "notchNotes.ownsSleepDisabled")
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.resetResult = true

        let store = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { true }
        )

        XCTAssertTrue(store.isKeepingAwake)
        XCTAssertFalse(store.isChangingKeepAwake)
        XCTAssertEqual(sleepGuard.resetCallCount, 0)

        store.recoverSleepAfterLaunchIfNeeded()
        await waitUntil { !store.isChangingKeepAwake }

        XCTAssertEqual(sleepGuard.resetCallCount, 1)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
        XCTAssertFalse(store.isKeepingAwake)
    }

    func testHelperFailureNeverClaimsSleepOwnership() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.completedSleepGuardRecoveryV1")
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.shouldSuspendReadiness = true
        sleepGuard.resetResult = true
        let store = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { false }
        )

        store.toggleKeepAwake()
        await waitUntil { sleepGuard.isWaitingForReadiness }

        XCTAssertTrue(store.isChangingKeepAwake)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))

        sleepGuard.resolveReadiness(.failure(SystemSleepGuardError.helperLaunchFailed("Helper unavailable")))
        await waitUntil { !store.isChangingKeepAwake }

        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertNotNil(store.keepAwakeErrorMessage)
    }

    func testPendingApprovalOffersSettingsWithoutStartingSession() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.completedSleepGuardRecoveryV1")
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.startError = .approvalRequired
        let store = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { false }
        )

        store.toggleKeepAwake()
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertFalse(store.isChangingKeepAwake)
        XCTAssertTrue(store.keepAwakeNeedsApproval)
        XCTAssertNotNil(store.keepAwakeErrorMessage)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
    }

    func testExternalDisabledSleepIsNotAdoptedOrMigratedAfterFailedStart() async {
        let defaults = makeDefaults()
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.resetResult = false
        let store = AppSettingsStore(defaults: defaults, systemSleepGuard: sleepGuard, sleepDisabledState: { true })
        store.recoverSleepAfterLaunchIfNeeded()
        XCTAssertEqual(sleepGuard.resetCallCount, 0)
        XCTAssertFalse(store.isKeepingAwake)
        store.toggleKeepAwake()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertFalse(sleepGuard.recoveredLegacyState)
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
    }

    func testOnlyLegacyOwnedStateRequestsLegacyRecovery() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.ownsSleepDisabled")
        let sleepGuard = FakeSystemSleepGuard()
        let store = AppSettingsStore(defaults: defaults, systemSleepGuard: sleepGuard, sleepDisabledState: { true })
        store.recoverSleepAfterLaunchIfNeeded()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertTrue(sleepGuard.recoveredLegacyState)
        XCTAssertTrue(defaults.bool(forKey: "notchNotes.completedPrivilegedSleepGuardMigrationV1"))
    }

    func testModernOwnedStateOnlyRequestsJournalRecovery() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.ownsSleepDisabled")
        defaults.set(true, forKey: "notchNotes.completedPrivilegedSleepGuardMigrationV1")
        let sleepGuard = FakeSystemSleepGuard()
        let store = AppSettingsStore(defaults: defaults, systemSleepGuard: sleepGuard, sleepDisabledState: { true })
        store.recoverSleepAfterLaunchIfNeeded()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertFalse(sleepGuard.recoveredLegacyState)
    }

    func testLegacyRecoveryCanRetryViaCoffeeAfterApproval() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.ownsSleepDisabled")
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.resetResult = false
        let store = AppSettingsStore(defaults: defaults, systemSleepGuard: sleepGuard, sleepDisabledState: { true })
        store.recoverSleepAfterLaunchIfNeeded()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertTrue(store.isKeepingAwake)
        XCTAssertTrue(sleepGuard.recoveredLegacyState)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.completedPrivilegedSleepGuardMigrationV1"))

        sleepGuard.resetResult = true
        store.toggleKeepAwake()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertEqual(sleepGuard.resetCallCount, 2)
        XCTAssertTrue(sleepGuard.recoveredLegacyState)
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
        XCTAssertTrue(defaults.bool(forKey: "notchNotes.completedPrivilegedSleepGuardMigrationV1"))
    }

    func testRepeatedCoffeeClicksStartOnceAndStopRestoresIdle() async {
        let defaults = makeDefaults()
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.shouldSuspendReadiness = true
        let store = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { false }
        )
        store.toggleKeepAwake()
        store.toggleKeepAwake()
        await waitUntil { sleepGuard.isWaitingForReadiness }
        sleepGuard.resolveReadiness(.success(()))
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertTrue(store.isKeepingAwake)
        XCTAssertEqual(sleepGuard.startCallCount, 1)
        XCTAssertTrue(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))

        store.toggleKeepAwake()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
    }

    func testUnexpectedHelperLossEndsTheAppSession() async {
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.shouldSuspendReadiness = true
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { false }
        )
        store.toggleKeepAwake()
        await waitUntil { sleepGuard.isWaitingForReadiness }
        sleepGuard.resolveReadiness(.success(()))
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertTrue(store.isKeepingAwake)

        sleepGuard.onUnexpectedStop?()
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertNotNil(store.keepAwakeErrorMessage)
    }

    func testQuittingWhileStartingCannotReactivateKeepAwake() async {
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.shouldSuspendReadiness = true
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { false }
        )
        store.toggleKeepAwake()
        await waitUntil { sleepGuard.isWaitingForReadiness }
        store.stopKeepingAwake()
        sleepGuard.resolveReadiness(.success(()))
        await waitUntil { !store.isChangingKeepAwake }
        XCTAssertFalse(store.isKeepingAwake)
    }

    func testLaunchAtLoginTogglesOnAndOffWithoutRegisteringOnInit() {
        let controller = FakeLaunchAtLoginController(status: .notRegistered)
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            sleepDisabledState: { false },
            launchAtLoginController: controller
        )

        XCTAssertTrue(store.canConfigureLaunchAtLogin)
        XCTAssertFalse(store.isLaunchAtLoginEnabled)
        XCTAssertNil(store.launchAtLoginErrorMessage)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertEqual(controller.registerCallCount, 0)
        XCTAssertEqual(controller.unregisterCallCount, 0)

        store.toggleLaunchAtLogin()
        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertTrue(store.isLaunchAtLoginEnabled)
        XCTAssertNil(store.launchAtLoginErrorMessage)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)

        store.toggleLaunchAtLogin()
        XCTAssertEqual(controller.unregisterCallCount, 1)
        XCTAssertFalse(store.isLaunchAtLoginEnabled)
        XCTAssertNil(store.launchAtLoginErrorMessage)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)

        controller.status = .enabled
        let restored = AppSettingsStore(
            defaults: makeDefaults(),
            sleepDisabledState: { false },
            launchAtLoginController: controller
        )
        XCTAssertTrue(restored.isLaunchAtLoginEnabled)
        XCTAssertEqual(controller.registerCallCount, 1)
    }

    func testUnpackagedEnvironmentBlocksLaunchAtLoginWithoutCallingRegister() {
        let controller = FakeLaunchAtLoginController(canConfigure: false, status: .notRegistered)
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            sleepDisabledState: { false },
            launchAtLoginController: controller
        )

        XCTAssertFalse(store.canConfigureLaunchAtLogin)
        XCTAssertFalse(store.isLaunchAtLoginEnabled)

        store.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(controller.registerCallCount, 0)
        XCTAssertFalse(store.isLaunchAtLoginEnabled)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertEqual(
            store.launchAtLoginErrorMessage,
            LaunchAtLoginError.notPackaged.userMessage
        )

        store.dismissLaunchAtLoginError()
        XCTAssertNil(store.launchAtLoginErrorMessage)

        store.setLaunchAtLoginEnabled(false)
        XCTAssertEqual(controller.unregisterCallCount, 0)
        XCTAssertFalse(store.isLaunchAtLoginEnabled)
        XCTAssertNil(store.launchAtLoginErrorMessage)
    }

    func testLaunchAtLoginRequiresApprovalSurfacesSettingsAction() {
        let controller = FakeLaunchAtLoginController(status: .notRegistered)
        controller.registerError = .approvalRequired
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            sleepDisabledState: { false },
            launchAtLoginController: controller
        )

        store.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertFalse(store.isLaunchAtLoginEnabled)
        XCTAssertTrue(store.launchAtLoginNeedsApproval)
        XCTAssertEqual(
            store.launchAtLoginErrorMessage,
            LaunchAtLoginError.approvalRequired.userMessage
        )

        store.openLaunchAtLoginApprovalSettings()
        XCTAssertEqual(controller.openApprovalSettingsCallCount, 1)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertNil(store.launchAtLoginErrorMessage)
    }

    func testRefreshLaunchAtLoginStateSyncsExternalChangesAndApplicationActivation() {
        let controller = FakeLaunchAtLoginController(status: .notRegistered)
        controller.registerError = .approvalRequired
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            sleepDisabledState: { false },
            launchAtLoginController: controller
        )

        store.setLaunchAtLoginEnabled(true)
        XCTAssertTrue(store.launchAtLoginNeedsApproval)
        XCTAssertNotNil(store.launchAtLoginErrorMessage)

        controller.status = .enabled
        store.refreshLaunchAtLoginState()
        XCTAssertTrue(store.isLaunchAtLoginEnabled)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertNil(store.launchAtLoginErrorMessage)

        controller.status = .requiresApproval
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        XCTAssertFalse(store.isLaunchAtLoginEnabled)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertNil(store.launchAtLoginErrorMessage)

        controller.status = .enabled
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        XCTAssertTrue(store.isLaunchAtLoginEnabled)
    }

    func testLaunchAtLoginUnregisterFailurePreservesEnabledStateAndReportsError() {
        let controller = FakeLaunchAtLoginController(status: .enabled)
        controller.unregisterError = .unregistrationFailed("Permission denied.")
        let store = AppSettingsStore(
            defaults: makeDefaults(),
            sleepDisabledState: { false },
            launchAtLoginController: controller
        )

        XCTAssertTrue(store.isLaunchAtLoginEnabled)

        store.setLaunchAtLoginEnabled(false)
        XCTAssertEqual(controller.unregisterCallCount, 1)
        XCTAssertTrue(store.isLaunchAtLoginEnabled)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertEqual(
            store.launchAtLoginErrorMessage,
            LaunchAtLoginError.unregistrationFailed("Permission denied.").userMessage
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removeTestSuiteAndPlist(named: suiteName)
        }
        return defaults
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class FakeSystemSleepGuard: SystemSleepGuardControlling {
    var onUnexpectedStop: (() -> Void)?
    var requiresApproval = false
    var startError: SystemSleepGuardError?
    private(set) var startCallCount = 0
    var isRunning = false
    var shouldSuspendReadiness = false
    var resetResult = true
    private(set) var isWaitingForReadiness = false
    private(set) var resetCallCount = 0
    private var readinessContinuation: CheckedContinuation<Void, Error>?

    func start() throws {
        startCallCount += 1
        if let startError { throw startError }
        isRunning = true
    }

    func waitUntilReady() async throws {
        guard shouldSuspendReadiness else {
            throw SystemSleepGuardError.helperLaunchFailed("Fake helper was not configured.")
        }

        isWaitingForReadiness = true
        return try await withCheckedThrowingContinuation { continuation in
            readinessContinuation = continuation
        }
    }

    func resolveReadiness(_ result: Result<Void, Error>) {
        isWaitingForReadiness = false
        readinessContinuation?.resume(with: result)
        readinessContinuation = nil
    }

    func requestStop() {
        isRunning = false
    }

    private(set) var recoveredLegacyState = false

    func resetSleepIfNeeded(includingLegacyState: Bool) async -> Bool {
        recoveredLegacyState = includingLegacyState
        resetCallCount += 1
        isRunning = false
        return resetResult
    }
}

@MainActor
private final class FakeLaunchAtLoginController: LaunchAtLoginControlling {
    var canConfigure: Bool
    var status: LaunchAtLoginStatus
    var registerError: LaunchAtLoginError?
    var unregisterError: LaunchAtLoginError?
    var statusAfterRegister: LaunchAtLoginStatus = .enabled
    var statusAfterUnregister: LaunchAtLoginStatus = .notRegistered
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openApprovalSettingsCallCount = 0

    init(
        canConfigure: Bool = true,
        status: LaunchAtLoginStatus = .notRegistered
    ) {
        self.canConfigure = canConfigure
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            if registerError == .approvalRequired {
                status = .requiresApproval
            }
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = statusAfterUnregister
    }

    func openApprovalSettings() {
        openApprovalSettingsCallCount += 1
    }
}

extension UserDefaults {
    func removeTestSuiteAndPlist(named suiteName: String) {
        removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }
}
