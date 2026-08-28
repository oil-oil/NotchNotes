import Foundation
import XCTest
@testable import NotchNotes

@MainActor
final class AppSettingsStoreTests: XCTestCase {
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

    func testFailedAuthorizationNeverClaimsSleepOwnership() async {
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

        sleepGuard.resolveReadiness(.failure(SystemSleepGuardError.authorizationDenied))
        await waitUntil { !store.isChangingKeepAwake }

        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertNotNil(store.keepAwakeErrorMessage)
    }

    func testCancelledAuthorizationReturnsToIdleWithoutErrorAlert() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "notchNotes.completedSleepGuardRecoveryV1")
        let sleepGuard = FakeSystemSleepGuard()
        sleepGuard.shouldSuspendReadiness = true
        let store = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: sleepGuard,
            sleepDisabledState: { false }
        )

        store.toggleKeepAwake()
        await waitUntil { sleepGuard.isWaitingForReadiness }
        sleepGuard.resolveReadiness(.failure(SystemSleepGuardError.authorizationCancelled))
        await waitUntil { !store.isChangingKeepAwake }

        XCTAssertFalse(store.isKeepingAwake)
        XCTAssertNil(store.keepAwakeErrorMessage)
        XCTAssertFalse(defaults.bool(forKey: "notchNotes.ownsSleepDisabled"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
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
    var isRunning = false
    var shouldSuspendReadiness = false
    var resetResult = true
    private(set) var isWaitingForReadiness = false
    private(set) var resetCallCount = 0
    private var readinessContinuation: CheckedContinuation<Void, Error>?

    func start() throws {
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

    func resetSleepIfNeeded() async -> Bool {
        resetCallCount += 1
        isRunning = false
        return resetResult
    }
}
