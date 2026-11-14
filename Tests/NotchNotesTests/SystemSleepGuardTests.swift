import Foundation
import ServiceManagement
import SleepGuardCore
import XCTest
@testable import NotchNotes

final class SystemSleepGuardTests: XCTestCase {
    func testSleepDisabledParserRequiresEnabledValue() {
        XCTAssertTrue(SleepGuardPowerState.isDisabled(in: "SleepDisabled\t\t1\n"))
        XCTAssertFalse(SleepGuardPowerState.isDisabled(in: "SleepDisabled 0\n"))
        XCTAssertFalse(SleepGuardPowerState.isDisabled(in: "sleep 1\n"))
    }

    @MainActor
    func testUnpackagedAppDoesNotFallBackToPasswordPrompt() {
        let sleepGuard = SystemSleepGuard()
        XCTAssertThrowsError(try sleepGuard.start()) { error in
            XCTAssertEqual(error as? SystemSleepGuardError, .notPackaged)
        }
        XCTAssertFalse(sleepGuard.isRunning)
    }

    @MainActor
    func testXPCErrorAndInvalidationOnBackgroundQueueDoNotTrapMainActorIsolation() async {
        let delegate = RejectingXPCListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepGuardXPC.self)

        let sleepGuard = SystemSleepGuard()
        let stopExpectation = expectation(description: "invalidation handler notifies main actor")
        sleepGuard.onUnexpectedStop = {
            stopExpectation.fulfill()
        }
        sleepGuard.configureConnectionForTesting(connection, markActive: true)

        do {
            try await sleepGuard.sendBeginForTesting(over: connection)
            XCTFail("Expected rejected anonymous XPC connection to throw an error")
        } catch {
            // Expected XPC error delivered on NSXPCConnection background queue.
        }

        await fulfillment(of: [stopExpectation], timeout: 2.0)
        XCTAssertFalse(sleepGuard.isRunning)
    }

    @MainActor
    func testEnsureServiceReRegistersWhenSigningSignatureChangesWithSameBuildNumber() async throws {
        let suiteName = "SystemSleepGuardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removeTestSuiteAndPlist(named: suiteName) }

        let service = FakeSleepDaemonService(initialStatus: .notRegistered)
        var currentSignature = "38\napp-cdhash-1\nhelper-cdhash-1"

        let sleepGuard = SystemSleepGuard(
            defaults: defaults,
            serviceFactory: { service },
            registrationSignatureProvider: { currentSignature },
            bundleValidator: {}
        )

        try await sleepGuard.ensureServiceIsEnabledForTesting()
        XCTAssertEqual(service.events, ["register"])

        // Same CFBundleVersion (38), unchanged signature -> reuses existing registration.
        service.events.removeAll()
        try await sleepGuard.ensureServiceIsEnabledForTesting()
        XCTAssertEqual(service.events, [])

        // Same CFBundleVersion (38), rebuilt ad-hoc cdhash -> must unregister then register.
        currentSignature = "38\napp-cdhash-2\nhelper-cdhash-2"
        service.events.removeAll()
        try await sleepGuard.ensureServiceIsEnabledForTesting()
        XCTAssertEqual(service.events, ["unregister", "register"])
    }

    @MainActor
    func testConnectionHandlersCanRunOnBackgroundQueue() async {
        let suiteName = "SystemSleepGuardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removeTestSuiteAndPlist(named: suiteName) }

        let sleepGuard = SystemSleepGuard(defaults: defaults)
        let connection = NSXPCConnection(machServiceName: "NotchNotesTests.unused")
        sleepGuard.configureConnectionForTesting(connection, id: UUID())
        defer { sleepGuard.requestStop() }

        let callbacks = ConnectionCallbacks(
            interrupted: connection.interruptionHandler!,
            invalidated: connection.invalidationHandler!
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                XCTAssertFalse(Thread.isMainThread)
                callbacks.interrupted()
                callbacks.invalidated()
                continuation.resume()
            }
        }
    }
}

private final class RejectingXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        false
    }
}

@MainActor
private final class FakeSleepDaemonService: SleepDaemonServiceManaging {
    var status: SMAppService.Status
    var events: [String] = []

    init(initialStatus: SMAppService.Status) {
        self.status = initialStatus
    }

    func register() throws {
        events.append("register")
        status = .enabled
    }

    func unregister() async throws {
        events.append("unregister")
        status = .notRegistered
    }
}

// NSXPCConnection invokes these unannotated Objective-C blocks off the main
// queue. Preserve their original types so the test catches inherited isolation.
private struct ConnectionCallbacks: @unchecked Sendable {
    let interrupted: () -> Void
    let invalidated: () -> Void
}
