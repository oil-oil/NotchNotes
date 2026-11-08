import Foundation
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
    func testConnectionHandlersCanRunOnBackgroundQueue() async {
        let sleepGuard = SystemSleepGuard()
        let connection = NSXPCConnection(machServiceName: "NotchNotesTests.unused")
        sleepGuard.configureConnectionHandlers(connection, id: UUID())
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

// NSXPCConnection invokes these unannotated Objective-C blocks off the main
// queue. Preserve their original types so the test catches inherited isolation.
private struct ConnectionCallbacks: @unchecked Sendable {
    let interrupted: () -> Void
    let invalidated: () -> Void
}
