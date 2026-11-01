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
}
