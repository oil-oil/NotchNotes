import Foundation
import XCTest
@testable import NotchNotes

final class SystemSleepGuardTests: XCTestCase {
    func testCommandDisablesSleepAndAlwaysRestoresIt() {
        let command = SystemSleepGuardCommand(
            appProcessID: 4321,
            readyFileURL: URL(fileURLWithPath: "/tmp/notch-notes.ready"),
            stopFileURL: URL(fileURLWithPath: "/tmp/notch-notes.stop")
        ).shellCommand

        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep 1"))
        XCTAssertTrue(command.contains("SleepDisabled[[:space:]]+1"))
        XCTAssertTrue(command.contains("trap cleanup 0 1 2 15"))
        XCTAssertTrue(command.contains("original_state=0"))
        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep \"$original_state\""))
        XCTAssertTrue(command.contains("/bin/kill -0 4321"))
        XCTAssertTrue(command.contains("[ ! -e '/tmp/notch-notes.stop' ]"))
    }

    func testCommandQuotesTemporaryPaths() {
        let command = SystemSleepGuardCommand(
            appProcessID: 7,
            readyFileURL: URL(fileURLWithPath: "/tmp/notch notes' ready"),
            stopFileURL: URL(fileURLWithPath: "/tmp/notch notes' stop")
        ).shellCommand

        XCTAssertTrue(command.contains("'/tmp/notch notes'\\'' ready'"))
        XCTAssertTrue(command.contains("'/tmp/notch notes'\\'' stop'"))
    }

    func testCommandIsValidShellSyntax() throws {
        let command = SystemSleepGuardCommand(
            appProcessID: 99,
            readyFileURL: URL(fileURLWithPath: "/tmp/notch-notes.ready"),
            stopFileURL: URL(fileURLWithPath: "/tmp/notch-notes.stop")
        ).shellCommand
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }
}
